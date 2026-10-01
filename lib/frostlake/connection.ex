defmodule Frostlake.Connection do
  @moduledoc """
  A connection to a Frostlake HTTP server, and the engine session behind it.

  One process, one HTTP session. Statements run in call order, which is what
  keeps `USE`, session variables and an open transaction carrying from one
  statement to the next — a half-interleaved second statement would break all
  three.

  Most callers reach this through `Frostlake`; the functions here are the same
  ones, and `start_link/1` is what a supervision tree wants:

      children = [
        {Frostlake.Connection, dsn: "frostlake://localhost:18082/MY_DB", name: MyApp.Frostlake}
      ]

  A supervised connection is not handed a statement while it starts up, so it
  does not contact the server in `c:GenServer.init/1`; the DSN's scope is applied
  ahead of the first statement instead. `Frostlake.connect/2` does contact it,
  and reports a database that does not exist there rather than on whichever
  query happened to run first.
  """

  use GenServer

  alias Frostlake.{Binding, Column, Config, ConnectionError, DSN, HTTP, JSON}
  alias Frostlake.{QueryError, Result, SessionLostError, SQL, UsageError, Values}

  @execute_path "/api/execute"
  @health_path "/api/health"
  @sessions_path "/api/sessions/"

  # How much of an unrecognisable response is quoted back in an error.
  @max_error_body 512

  # The most closing may spend handing the session back to the engine.
  @release_limit 5_000

  defmodule State do
    @moduledoc false

    defstruct [
      :config,
      :socket,
      :session_id,
      :last_used_at,
      reused: false,
      auto_commit: true,
      pending_use: [],
      session_defaults: [],
      session_touched: false,
      # Whether the engine marks its answers `newSession`, as engines from 0.1.0
      # on do; nil until an answer names a session.
      tracks_sessions: nil,
      # Whether a statement left state behind that a fresh session would not
      # have (see SQL.touches_session?/1), so that losing the session loses it.
      dirty: false,
      # Whether a transaction is open on the session, begun by begin/2 or in SQL.
      in_transaction: false,
      # Set once a transaction went with a lost session, until commit/2,
      # rollback/2 or begin/2 hears of it: a commit must not answer :ok for it.
      transaction_lost: false,
      # The monitor on the process that opened the connection, if any.
      owner_ref: nil,
      # The time limit of the call in progress, for the message a timeout gets.
      limit: nil
    ]
  end

  @type conn :: GenServer.server()

  @doc """
  Starts a connection process.

  Options are `:dsn` or `:config`, anything `Frostlake.connect/2` accepts,
  `:name`, which is passed to `GenServer.start_link/3`, and `:owner`, a process
  whose end — normal or not — ends the connection too.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    {owner, opts} = Keyword.pop(opts, :owner)
    {server_opts, opts} = if name, do: {[name: name], opts}, else: {[], opts}

    case build_config(opts) do
      {:ok, config} -> GenServer.start_link(__MODULE__, {config, owner}, server_opts)
      {:error, error} -> {:error, error}
    end
  end

  @doc false
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  defp build_config(opts) do
    {dsn, opts} = Keyword.pop(opts, :dsn)
    {config, opts} = Keyword.pop(opts, :config)

    cond do
      config && dsn ->
        {:error, %UsageError{message: "give either :dsn or :config, not both"}}

      config ->
        {:ok, DSN.apply_options(config, opts)}

      is_binary(dsn) ->
        DSN.parse(dsn, opts)

      true ->
        {:error, %UsageError{message: "a connection needs a :dsn or a :config"}}
    end
  end

  @doc """
  Checks that the server is answering and puts the session on the DSN's scope.

  `Frostlake.connect/2` calls this; it is worth calling again only after the
  session has been moved somewhere else deliberately.
  """
  @spec handshake(conn()) :: :ok | {:error, Exception.t()}
  def handshake(conn) do
    with :ok <- ping(conn), do: apply_scope(conn)
  end

  @doc "Runs one statement and returns every result set it produced, in order."
  @spec execute(conn(), String.t(), String.t(), keyword()) ::
          {:ok, [Result.t()]} | {:error, Exception.t()}
  def execute(conn, sql, rendered, opts \\ []) do
    with {:ok, timeout} <- timeout_option(opts),
         {:ok, count} <- statement_count_option(opts) do
      call(conn, {:execute, sql, rendered, timeout, count})
    end
  end

  @doc "Checks that a Frostlake engine is answering, via `GET /api/health`."
  @spec ping(conn(), keyword()) :: :ok | {:error, Exception.t()}
  def ping(conn, opts \\ []), do: command(conn, :ping, opts)

  @doc "Selects the database, schema, role and warehouse the DSN names."
  @spec apply_scope(conn(), keyword()) :: :ok | {:error, Exception.t()}
  def apply_scope(conn, opts \\ []), do: command(conn, :apply_scope, opts)

  @doc "Opens a transaction: autocommit goes off and `BEGIN` is sent."
  @spec begin(conn(), keyword()) :: :ok | {:error, Exception.t()}
  def begin(conn, opts \\ []), do: command(conn, :begin, opts)

  @doc "Commits the open transaction and restores autocommit."
  @spec commit(conn(), keyword()) :: :ok | {:error, Exception.t()}
  def commit(conn, opts \\ []), do: command(conn, :commit, opts)

  @doc "Rolls the open transaction back and restores autocommit."
  @spec rollback(conn(), keyword()) :: :ok | {:error, Exception.t()}
  def rollback(conn, opts \\ []), do: command(conn, :rollback, opts)

  defp command(conn, message, opts) do
    with {:ok, timeout} <- timeout_option(opts) do
      call(conn, {message, timeout})
    end
  end

  # How many statements the request declares: the engine refuses a string
  # holding any other number before running any of it, and `0` accepts any
  # number. nil declares nothing, which leaves it to the session's
  # MULTI_STATEMENT_COUNT.
  defp statement_count_option(opts) do
    case Keyword.get(opts, :multi_statement_count) do
      nil ->
        {:ok, nil}

      count when is_integer(count) and count >= 0 ->
        {:ok, count}

      other ->
        {:error,
         %UsageError{
           message:
             ":multi_statement_count must be a non-negative number of statements, " <>
               "0 for any number, got #{inspect(other)}"
         }}
    end
  end

  # Checked here rather than in the connection process: a bad :timeout is the
  # caller's mistake, and it should come back as one rather than take the
  # connection down with it.
  defp timeout_option(opts) do
    case Keyword.get(opts, :timeout) do
      nil ->
        {:ok, nil}

      :infinity ->
        {:ok, :infinity}

      timeout when is_integer(timeout) and timeout >= 0 ->
        {:ok, timeout}

      other ->
        {:error,
         %UsageError{
           message:
             ":timeout must be a non-negative number of milliseconds or :infinity, " <>
               "got #{inspect(other)}"
         }}
    end
  end

  @doc "The engine's id for this connection's session, once it has one."
  @spec session_id(conn()) :: String.t() | nil
  def session_id(conn), do: call(conn, :session_id)

  @doc "Whether `begin/2` has run without a matching `commit/2` or `rollback/2`."
  @spec in_transaction?(conn()) :: boolean()
  def in_transaction?(conn), do: call(conn, :in_transaction?)

  @doc "The configuration this connection was opened with."
  @spec config(conn()) :: Config.t()
  def config(conn), do: call(conn, :config)

  @doc """
  Closes the connection and hands its session back to the engine.

  A statement already in flight finishes first — its caller gets an answer
  rather than a torn socket. From engine 0.1.0 on the session is then ended
  with `DELETE /api/sessions/{id}`, which rolls back a transaction left open in
  it; an earlier engine has no such endpoint and keeps the session until its
  own idle sweep. Releasing is best effort: it waits no longer than the
  connection's timeout or five seconds, whichever is shorter, and closing
  succeeds whatever the engine answers, or if it does not answer at all.
  """
  @spec close(conn()) :: :ok
  def close(conn) do
    GenServer.stop(conn, :normal)
  catch
    :exit, _ -> :ok
  end

  # A call on a connection that has been closed exits, the way a call on any
  # dead process does. That is a usage mistake rather than a transport failure,
  # so it is reported as one.
  defp call(conn, message) do
    GenServer.call(conn, message, :infinity)
  catch
    :exit, {reason, _details} when reason in [:noproc, :normal, :shutdown] ->
      {:error, %UsageError{message: "the connection is closed"}}
  end

  ## Server

  @impl true
  def init({%Config{} = config, owner}) do
    {:ok, state} = init(config)
    # A link only follows an ABNORMAL exit: a caller that finished normally
    # would leave the process, its socket and its engine session behind.
    ref = if is_pid(owner), do: Process.monitor(owner)
    {:ok, %{state | owner_ref: ref}}
  end

  def init(%Config{} = config) do
    use_statements = Config.use_statements(config)

    {:ok,
     %State{
       config: config,
       pending_use: use_statements,
       session_defaults: use_statements
     }}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _owner, _reason}, %State{owner_ref: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call({:execute, sql, rendered, timeout, count}, _from, state) do
    state = with_limit(state, timeout)
    deadline = deadline(state, timeout)

    # The declared count travels with the caller's statement only: the USE
    # statements drained ahead of it are one statement each.
    with {:ok, state} <- drain_pending_use(restore_session_defaults(state), deadline),
         {:ok, body, state} <- run(state, rendered, deadline, count) do
      # A statement that moves the session keeps the DSN's defaults off it from
      # then on. Not one that met a replaced session: the DSN's scope is queued
      # to go back on over it (see note_new_session/3).
      state =
        if SQL.changes_session_scope?(sql) and state.pending_use == [],
          do: %{state | session_touched: true},
          else: state

      {:reply, {:ok, shape_results(body)}, state}
    else
      {:error, error, state} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:ping, timeout}, _from, state) do
    state = with_limit(state, timeout)

    case health(state, deadline(state, timeout)) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, error, state} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:apply_scope, timeout}, _from, state) do
    state = with_limit(state, timeout)

    # Re-queue the whole scope: the handshake drained the queue already, so
    # without this a second call would send nothing and report success.
    state = %{state | pending_use: state.session_defaults, session_touched: false}

    case drain_pending_use(state, deadline(state, timeout)) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, error, state} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:begin, timeout}, _from, state) do
    state = with_limit(%{state | transaction_lost: false}, timeout)

    case run(%{state | auto_commit: false}, "BEGIN", deadline(state, timeout)) do
      {:ok, _body, state} -> {:reply, :ok, %{state | auto_commit: false}}
      {:error, error, state} -> {:reply, {:error, error}, %{state | auto_commit: true}}
    end
  end

  def handle_call({:commit, timeout}, _from, state) do
    finish_transaction(state, "COMMIT", timeout)
  end

  def handle_call({:rollback, timeout}, _from, state) do
    finish_transaction(state, "ROLLBACK", timeout)
  end

  def handle_call(:session_id, _from, state), do: {:reply, state.session_id, state}
  def handle_call(:in_transaction?, _from, state), do: {:reply, not state.auto_commit, state}
  def handle_call(:config, _from, state), do: {:reply, state.config, state}

  @impl true
  def terminate(_reason, state) do
    state = release_session(state)
    HTTP.close(state.socket)
    :ok
  end

  # Engine 0.1.0 ends a session on `DELETE /api/sessions/{id}` and rolls back a
  # transaction left open in it; otherwise the session, and whatever it holds,
  # lingers until the engine's idle sweep reclaims it. Closing must neither fail
  # nor hang on it: the answer is ignored whatever it says — a 404 for a session
  # already gone included — a transport failure is swallowed, and the request
  # gets the connection's own timeout or five seconds, whichever is shorter. An
  # engine that never marks an answer `newSession` predates the endpoint and is
  # not asked.
  defp release_session(%State{session_id: nil} = state), do: state
  defp release_session(%State{tracks_sessions: false} = state), do: state

  defp release_session(%State{config: config} = state) do
    limit = release_limit(config.timeout)
    connect_timeout = release_limit(config.connect_timeout)
    state = %{state | config: %{config | connect_timeout: connect_timeout}, limit: limit}
    path = @sessions_path <> URI.encode(state.session_id, &URI.char_unreserved?/1)

    case perform(state, "DELETE", path, nil, HTTP.deadline(limit)) do
      {:ok, _status, _response, state} -> state
      {:error, _error, state} -> state
    end
  catch
    _kind, _reason -> state
  end

  # A limit of 0 means none at all, which closing does not get.
  defp release_limit(0), do: @release_limit
  defp release_limit(limit), do: min(limit, @release_limit)

  # A transaction that went with a lost session was reported by the statement
  # that met the loss. It cannot be committed, and nothing is left to roll back,
  # so neither sends anything; a commit says so rather than answer :ok.
  defp finish_transaction(%State{transaction_lost: true} = state, statement, _timeout) do
    state = %{state | transaction_lost: false, auto_commit: true}

    if statement == "COMMIT" do
      error = %SessionLostError{
        message:
          "the engine no longer holds this connection's session, so the transaction went " <>
            "with it and nothing in it was committed",
        statement: statement
      }

      {:reply, {:error, error}, state}
    else
      {:reply, :ok, state}
    end
  end

  defp finish_transaction(state, statement, timeout) do
    state = with_limit(state, timeout)

    case run(state, statement, deadline(state, timeout)) do
      # The answer said the engine ran it in a fresh session: the transaction had
      # gone before it arrived.
      {:ok, _body, %State{transaction_lost: true} = state} ->
        finish_transaction(state, statement, timeout)

      {:ok, _body, state} ->
        {:reply, :ok, %{state | auto_commit: true}}

      {:error, error, state} ->
        {:reply, {:error, error}, %{state | auto_commit: true, transaction_lost: false}}
    end
  end

  # Each USE leaves the queue only once it has succeeded. A DSN naming a
  # database that does not exist has to keep failing; the alternative is later
  # statements quietly running in the default scope.
  #
  # A USE that meets a replaced session puts the whole scope back in the queue
  # (see note_new_session/3), since those sent before it went with the old
  # session; when it was not the first of the scope, the queue starts over. Only
  # once: an engine that replaces the session again within the same few
  # requests is keeping none, and another pass would not change that.
  defp drain_pending_use(state, deadline, restarted \\ false)

  defp drain_pending_use(%State{pending_use: []} = state, _deadline, _restarted), do: {:ok, state}

  defp drain_pending_use(%State{pending_use: [statement | rest]} = state, deadline, restarted) do
    queue = state.pending_use

    case round_trip(state, statement, deadline) do
      {:ok, _body, %State{pending_use: ^queue} = state} ->
        drain_pending_use(%{state | pending_use: rest}, deadline, restarted)

      {:ok, _body, state} when not restarted ->
        drain_pending_use(state, deadline, true)

      {:ok, _body, state} ->
        drain_pending_use(%{state | pending_use: rest}, deadline, restarted)

      # The session was gone before its scope was back on. An open transaction
      # went with it, which the caller has to hear about; otherwise the whole
      # scope goes onto a fresh session, once, as above.
      {:gone, state} ->
        cond do
          state.in_transaction ->
            {:error, transaction_gone(statement), lose_transaction(forget_session(state))}

          restarted ->
            {:error, refused_fresh(statement), forget_session(state)}

          true ->
            drain_pending_use(forget_session(state), deadline, true)
        end

      {:error, error, state} ->
        {:error, error, state}
    end
  end

  # One statement, recovered as a lost session allows (see recover/4), with what
  # it leaves on the session noted once it has run.
  defp run(state, statement, deadline, count \\ nil) do
    case round_trip(state, statement, deadline, count) do
      {:gone, state} -> recover(state, statement, deadline, count)
      answer -> answer
    end
    |> track(statement)
  end

  # The engine no longer holds the session — it expired, was released, or went
  # with a restart — and nothing ran. With a transaction or a moved context gone
  # with it, re-running would put the statement somewhere its author did not
  # intend, so the loss is reported instead; otherwise a fresh session on the
  # DSN's scope takes over and the statement is sent once more. Either way the
  # next statement starts on a fresh session.
  defp recover(state, statement, deadline, count) do
    cond do
      state.in_transaction ->
        {:error, transaction_gone(statement), lose_transaction(forget_session(state))}

      state.dirty ->
        {:error, context_gone(statement), forget_session(state)}

      true ->
        with {:ok, state} <- drain_pending_use(forget_session(state), deadline) do
          case round_trip(state, statement, deadline, count) do
            {:gone, state} -> {:error, refused_fresh(statement), forget_session(state)}
            answer -> answer
          end
        end
    end
  end

  # A session the engine no longer holds, and everything it held, forgotten: the
  # next request starts a fresh one, with the DSN's scope put back on first.
  defp forget_session(state) do
    %{
      state
      | session_id: nil,
        dirty: false,
        in_transaction: false,
        session_touched: false,
        pending_use: state.session_defaults
    }
  end

  defp lose_transaction(state), do: %{state | auto_commit: true, transaction_lost: true}

  defp transaction_gone(statement) do
    %SessionLostError{
      message:
        "the engine no longer holds this connection's session (it expired, was released, " <>
          "or the server restarted), so its open transaction is gone; the statement did not run",
      statement: statement
    }
  end

  defp context_gone(statement) do
    %SessionLostError{
      message:
        "the engine no longer holds this connection's session (it expired, was released, " <>
          "or the server restarted), and the context set up on it (USE, SET, ALTER SESSION " <>
          "or a temporary object) went with it, so the statement was not re-run; the next " <>
          "statement starts a fresh session on the DSN's scope",
      statement: statement
    }
  end

  defp refused_fresh(statement) do
    %SessionLostError{
      message: "the engine refused a session it had just started",
      statement: statement
    }
  end

  # What a statement that ran leaves on the session: a moved context, or a
  # transaction opened or ended.
  defp track({:ok, body, state}, statement) do
    state =
      statement
      |> SQL.split_statements()
      |> Enum.reduce(state, fn piece, state ->
        state = if SQL.touches_session?(piece), do: %{state | dirty: true}, else: state

        case SQL.transaction_effect(piece) do
          :begins -> %{state | in_transaction: true}
          :ends -> %{state | in_transaction: false}
          :none -> state
        end
      end)

    {:ok, body, state}
  end

  defp track(answer, _statement), do: answer

  # An engine before 0.1.0 reclaims a session once it has been idle long enough,
  # then quietly builds a fresh one for the id we keep sending — losing the scope
  # we selected — and nothing in its answer gives that away. So past the limit
  # the safe reading is that the session is new, and the DSN's defaults go back
  # on ahead of the statement.
  #
  # An engine that marks its answers `newSession` is sent `requireSession`
  # instead, and refuses a session it no longer holds before anything runs (see
  # recover/4), so it needs no guessing; and until an answer has said which kind
  # of engine this is, no session has been named to guess about.
  #
  # Not once the caller has selected a scope themselves: putting our defaults
  # over their choice is its own surprise.
  defp restore_session_defaults(%State{tracks_sessions: tracks} = state) when tracks != false,
    do: state

  defp restore_session_defaults(%State{session_defaults: []} = state), do: state
  defp restore_session_defaults(%State{session_touched: true} = state), do: state
  defp restore_session_defaults(%State{config: %Config{idle_limit: 0}} = state), do: state
  defp restore_session_defaults(%State{last_used_at: nil} = state), do: state

  defp restore_session_defaults(%State{} = state) do
    idle = System.monotonic_time(:millisecond) - state.last_used_at

    if idle < state.config.idle_limit do
      state
    else
      %{state | pending_use: state.session_defaults}
    end
  end

  defp round_trip(state, sql, deadline, count \\ nil) do
    # Only an answer to a request naming a session can say it was replaced: the
    # very first request always starts one.
    held = state.session_id != nil

    payload =
      %{"sql" => sql, "autoCommit" => state.auto_commit}
      |> maybe_put("sessionId", state.session_id)
      # Resume the session or refuse: otherwise an engine that no longer holds it
      # starts a fresh one under the same id, at the server's default scope.
      # Only for an engine known to mark `newSession`: one before 0.1.0 may refuse
      # a field it does not know.
      |> maybe_put("requireSession", if(held and state.tracks_sessions == true, do: true))
      |> maybe_put("multiStatementCount", count)
      |> JSON.encode_to_iodata()

    endpoint = endpoint(state, @execute_path)

    case perform(state, "POST", @execute_path, payload, deadline) do
      {:ok, status, response, state} ->
        case decode_body(endpoint, status, response) do
          {:ok, body} when status == 404 and held ->
            if session_refused?(body) do
              # The engine refused the session it was asked to resume, as one it
              # no longer holds (`requireSession`): nothing ran.
              {:gone, state}
            else
              answered(state, body, held, sql, status, response)
            end

          {:ok, body} ->
            answered(state, body, held, sql, status, response)

          {:error, error} ->
            {:error, error, state}
        end

      {:error, error, state} ->
        {:error, error, state}
    end
  end

  defp session_refused?(body), do: body["success"] != true and body["sessionId"] == nil

  defp answered(state, body, held, sql, status, response) do
    # Any answer proves the session was alive just now, which is what the idle
    # limit measures: a statement the engine refused is still a statement it
    # answered.
    state = remember_session(state, body, held)
    state = %{state | last_used_at: System.monotonic_time(:millisecond)}

    if body["success"] == true do
      {:ok, body, state}
    else
      error = %QueryError{
        message: failure_message(body, status, response),
        statement: sql,
        status: status
      }

      {:error, error, state}
    end
  end

  # A 200 on its own only says something is listening — anything can serve that.
  # The health payload is what says it is an engine, so a body that is not one is
  # reported rather than passed off as healthy.
  defp health(state, deadline) do
    endpoint = endpoint(state, @health_path)

    case perform(state, "GET", @health_path, nil, deadline) do
      {:ok, status, response, state} ->
        case decode_body(endpoint, status, response) do
          {:ok, body} ->
            if status == 200 and body["status"] != nil do
              {:ok, state}
            else
              {:error, not_frostlake(endpoint, status, response), state}
            end

          {:error, error} ->
            {:error, error, state}
        end

      {:error, error, state} ->
        {:error, error, state}
    end
  end

  defp perform(state, method, path, body, deadline) do
    case ensure_socket(state) do
      {:ok, state} -> send_request(state, method, path, body, deadline)
      {:error, error, state} -> {:error, error, state}
    end
  end

  defp send_request(state, method, path, body, deadline) do
    reused = state.reused
    host = Config.host_header(state.config)

    case HTTP.request(state.socket, method, path, host, body, deadline) do
      {:ok, status, headers, response} ->
        state = %{state | reused: true}
        state = if HTTP.keep_alive?(headers), do: state, else: drop_socket(state)
        {:ok, status, response, state}

      # A socket kept from an earlier statement, and a write that never left the
      # host: the server had finished with the socket before the request went
      # out, so nothing ran and re-sending it cannot run anything twice. A fresh
      # socket never takes this path, so the retry cannot repeat.
      {:error, _reason, :not_sent} when reused ->
        perform(drop_socket(state), method, path, body, deadline)

      # Anything else — including a request that went out and was never answered
      # — leaves the statement's fate unknown, and an unknown INSERT is not
      # re-sent.
      {:error, reason, _phase} ->
        {:error, transport_error(state, path, reason), drop_socket(state)}
    end
  end

  defp ensure_socket(%State{socket: nil} = state) do
    case HTTP.connect(state.config) do
      {:ok, socket} ->
        {:ok, %{state | socket: socket, reused: false}}

      {:error, reason} ->
        error = %ConnectionError{
          message: "cannot reach #{Config.base_url(state.config)}: #{describe_reason(reason)}",
          endpoint: Config.base_url(state.config),
          reason: reason
        }

        {:error, error, state}
    end
  end

  defp ensure_socket(%State{} = state) do
    if HTTP.alive?(state.socket) do
      {:ok, state}
    else
      state |> drop_socket() |> ensure_socket()
    end
  end

  defp drop_socket(%State{} = state) do
    HTTP.close(state.socket)
    %{state | socket: nil, reused: false}
  end

  # The limit that actually applied to the call: the statement's own when it
  # had one, otherwise the connection's.
  defp with_limit(state, nil), do: %{state | limit: state.config.timeout}
  defp with_limit(state, :infinity), do: %{state | limit: 0}
  defp with_limit(state, timeout) when is_integer(timeout), do: %{state | limit: timeout}
  defp with_limit(state, _timeout), do: state

  defp transport_error(state, path, :timeout) do
    limit = state.limit || state.config.timeout

    %ConnectionError{
      message: "#{endpoint(state, path)} did not answer within #{describe_limit(limit)}",
      endpoint: endpoint(state, path),
      reason: :timeout
    }
  end

  defp transport_error(state, path, reason) do
    %ConnectionError{
      message: "#{endpoint(state, path)}: #{describe_reason(reason)}",
      endpoint: endpoint(state, path),
      reason: reason
    }
  end

  # A proxy error page, the wrong port, a crashed server: report what came back
  # rather than where the JSON parser gave up, which is the difference between
  # "malformed JSON at offset 0" and a message naming the address that answered.
  defp decode_body(endpoint, status, response) do
    case JSON.decode(response) do
      {:ok, body} when is_map(body) -> {:ok, body}
      _ -> {:error, not_frostlake(endpoint, status, response)}
    end
  end

  defp not_frostlake(endpoint, status, response) do
    %ConnectionError{
      message:
        "#{endpoint} answered HTTP #{status || "?"} with a body that is not a " <>
          "Frostlake response: #{snippet(response)}",
      endpoint: endpoint,
      status: status
    }
  end

  defp remember_session(state, body, held) do
    case body["sessionId"] do
      session when is_binary(session) and session != "" ->
        note_new_session(%{state | session_id: session}, body["newSession"], held)

      _ ->
        state
    end
  end

  # From engine 0.1.0 on, an answer naming a session says whether the statement
  # ran in one the engine had only just started. To a request naming ours that
  # means ours was gone — idle past the engine's limit, released, or lost to a
  # restart — and the statement ran in a fresh session at the server's default
  # scope. It has run, and nothing takes that back; what can be done is to put
  # the DSN's scope back on before the next statement. A USE of the caller's own
  # went with the old session, so it no longer holds the defaults off.
  #
  # The mark's presence is also what says the engine can release a session on
  # close; an answer without one comes from an engine before 0.1.0.
  defp note_new_session(state, true, true) do
    state = if state.in_transaction, do: lose_transaction(state), else: state

    %{
      state
      | tracks_sessions: true,
        pending_use: state.session_defaults,
        session_touched: false,
        dirty: false,
        in_transaction: false
    }
  end

  defp note_new_session(state, mark, _held) when is_boolean(mark) do
    %{state | tracks_sessions: true}
  end

  defp note_new_session(state, _mark, _held) do
    %{state | tracks_sessions: state.tracks_sessions || false}
  end

  # Never returns the empty string: a response can report failure carrying no
  # message at all, and an error that prints as nothing tells the caller less
  # than the status code would.
  defp failure_message(body, status, response) do
    cond do
      is_binary(body["errorMessage"]) and body["errorMessage"] != "" ->
        body["errorMessage"]

      is_binary(body["error"]) and body["error"] != "" ->
        body["error"]

      true ->
        "the statement failed with HTTP #{status} and no error message: #{snippet(response)}"
    end
  end

  ## Shaping

  defp shape_results(body) do
    case body["resultSets"] do
      [_ | _] = sets -> sets |> Enum.filter(&is_map/1) |> Enum.map(&shape_result/1)
      _ -> [%Result{}]
    end
  end

  defp shape_result(set) do
    columns = set |> Map.get("columns") |> shape_columns()
    rows = set |> Map.get("rows") |> shape_rows(columns)

    case counters(columns, rows) do
      nil ->
        %Result{columns: columns, rows: rows, num_rows: length(rows), update_count: -1}

      {affected, counters} ->
        # The grid itself is kept rather than folded away. A statement whose
        # answer merely LOOKS like a status grid is indistinguishable from one
        # that is — `… ->> SELECT * FROM $1` reads a DML result as a table, and
        # hiding its rows lost the only copy of them.
        %Result{
          columns: columns,
          rows: rows,
          num_rows: affected,
          update_count: affected,
          counters: counters
        }
    end
  end

  defp shape_columns(columns) when is_list(columns) do
    for column <- columns, is_map(column) do
      %Column{
        name: as_string(column["name"]) || "",
        data_type: as_string(column["dataType"]) || "",
        nullable: if(is_boolean(column["nullable"]), do: column["nullable"]),
        precision: as_integer(column["precision"]),
        scale: as_integer(column["scale"])
      }
    end
  end

  defp shape_columns(_columns), do: []

  defp shape_rows(rows, columns) when is_list(rows) do
    for row <- rows, is_list(row), do: convert_row(columns, row)
  end

  defp shape_rows(_rows, _columns), do: []

  # Cells are aligned to the columns rather than to each other: a row the server
  # cut short still answers for every column it declared.
  defp convert_row([], _cells), do: []

  defp convert_row([column | columns], [cell | cells]) do
    [Values.convert_cell(cell, column) | convert_row(columns, cells)]
  end

  defp convert_row([column | columns], []) do
    [Values.convert_cell(nil, column) | convert_row(columns, [])]
  end

  # The protocol carries no statement type, so a DML answer is recognised by its
  # shape: a single row whose every column is a "number of …" counter. INSERT and
  # DELETE report one, UPDATE adds "number of multi-joined rows updated", and
  # MERGE reports an inserted and an updated count.
  defp counters([_ | _] = columns, [row]) do
    if Enum.all?(columns, &String.starts_with?(String.downcase(&1.name), "number of ")) do
      columns
      |> Enum.zip(row)
      |> Enum.reduce({0, %{}}, fn {column, cell}, {affected, counters} = unchanged ->
        case as_integer(cell) do
          nil ->
            unchanged

          count ->
            # "number of multi-joined rows updated" is a diagnostic sub-count of
            # rows already counted as updated, so only the "number of rows …"
            # counters are summed.
            rows? = String.starts_with?(String.downcase(column.name), "number of rows ")
            {affected + if(rows?, do: count, else: 0), Map.put(counters, column.name, count)}
        end
      end)
    end
  end

  defp counters(_columns, _rows), do: nil

  defp as_string(value) when is_binary(value), do: value
  defp as_string(_value), do: nil

  defp as_integer(value) when is_integer(value), do: value
  defp as_integer(value) when is_float(value), do: if(trunc(value) == value, do: trunc(value))

  defp as_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp as_integer(_value), do: nil

  ## Odds and ends

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp endpoint(state, path), do: Config.base_url(state.config) <> path

  defp deadline(state, nil), do: HTTP.deadline(state.config.timeout)
  defp deadline(_state, :infinity), do: HTTP.deadline(0)

  defp deadline(_state, timeout) when is_integer(timeout) and timeout >= 0 do
    HTTP.deadline(timeout)
  end

  defp deadline(_state, timeout) do
    raise UsageError,
      message:
        ":timeout must be a non-negative number of milliseconds or :infinity, " <>
          "got #{inspect(timeout)}"
  end

  defp describe_limit(0), do: "no time at all"
  defp describe_limit(limit) when limit < 1000, do: "#{limit}ms"

  defp describe_limit(limit) do
    seconds = limit / 1000
    if seconds == trunc(seconds), do: "#{trunc(seconds)}s", else: "#{seconds}s"
  end

  defp describe_reason(:closed), do: "the connection was closed"
  defp describe_reason(:timeout), do: "the deadline passed"
  defp describe_reason(:econnrefused), do: "connection refused"
  defp describe_reason(:nxdomain), do: "the host is unknown"
  defp describe_reason(:ehostunreach), do: "the host is unreachable"

  defp describe_reason(:no_trusted_certificates),
    do:
      "no trusted certificates are available; pass :cacerts or :cacertfile, " <>
        "or verify_certificate: false"

  defp describe_reason({:tls_alert, {_alert, detail}}), do: "TLS: #{detail}"
  defp describe_reason(reason) when is_atom(reason), do: to_string(reason)
  defp describe_reason(reason), do: inspect(reason)

  defp snippet(payload) do
    text = String.trim(payload || "")

    cond do
      text == "" -> "(empty body)"
      byte_size(text) > @max_error_body -> binary_part(text, 0, @max_error_body) <> "…"
      true -> text
    end
  end

  @doc false
  # Kept next to the connection so a caller reading a QueryError can see the
  # statement rendering that produced it.
  def render(sql, parameters) do
    {:ok, Binding.substitute(sql, parameters)}
  rescue
    error in UsageError -> {:error, error}
  end
end
