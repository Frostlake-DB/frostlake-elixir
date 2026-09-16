defmodule Frostlake do
  @moduledoc """
  A dependency-free Elixir driver for [Frostlake](https://frostlake.dev),
  speaking the engine's HTTP protocol against a running `DatabaseHttpServer`.

      {:ok, conn} = Frostlake.connect("frostlake://localhost:18082/MY_DB?schema=PUBLIC")

      {:ok, _} = Frostlake.execute(conn, "CREATE TABLE people (id INTEGER, name VARCHAR)")

      {:ok, inserted} =
        Frostlake.execute(conn, "INSERT INTO people VALUES (?, ?), (?, ?)", [1, "Ada", 2, "Grace"])

      inserted.update_count
      #=> 2

      {:ok, result} = Frostlake.execute(conn, "SELECT id, name FROM people WHERE id = ?", [1])
      result.rows
      #=> [[1, "Ada"]]

      :ok = Frostlake.close(conn)

  Every call answers `{:ok, value}` or `{:error, exception}`; the `!` variants
  raise instead. The three exceptions say which kind of failure it was, which is
  the distinction a caller actually branches on: `Frostlake.QueryError` (the
  engine refused the statement), `Frostlake.ConnectionError` (the request never
  became an answer, so the statement's fate is unknown) and
  `Frostlake.UsageError` (the driver never sent it).

  ## Parameters

  Parameters are inlined client-side — the protocol has no server-side binding.
  A list fills positional `?` markers in order; a map or keyword list fills
  `:name` markers, case-insensitively and in any order:

      Frostlake.execute(conn, "SELECT :a + :b AS total", a: 2, b: 40)

  See `Frostlake.Binding` for the full value mapping, and `Frostlake.Values` for
  what comes back.

  ## In a supervision tree

      children = [
        {Frostlake.Connection, dsn: "frostlake://localhost:18082/MY_DB", name: MyApp.DB}
      ]

  Statements then run as `Frostlake.execute(MyApp.DB, sql)`.
  """

  alias Frostlake.{Connection, Result}

  @typedoc "A connection process: a pid, or the name one was registered under."
  @type conn :: Connection.conn()

  @typedoc "Anything the driver reports as a failure."
  @type error ::
          Frostlake.QueryError.t() | Frostlake.ConnectionError.t() | Frostlake.UsageError.t()

  @typedoc "Positional parameters as a list, or named ones as a map or keyword list."
  @type params :: list() | map()

  @doc """
  Opens a connection.

  The server is contacted before this returns: its health endpoint is called,
  and the database, schema, role and warehouse the DSN names are selected. A
  name that does not exist is therefore reported here, rather than surfacing
  later on whichever query happened to run first.

  ## Options

  Every DSN parameter may be given here instead, where it outranks the DSN:
  `:database`, `:schema`, `:role`, `:warehouse`, `:timeout`, `:connect_timeout`,
  `:idle_limit`, `:tls`, `:verify_certificate`, `:cacerts` and `:cacertfile`.
  Durations are milliseconds, or the string spelling a DSN uses (`"30s"`).
  `:name` registers the connection process under a name.

  The connection is linked to the calling process and monitors it, so it goes
  away with it — on a normal exit too, which a link alone would not notice.
  """
  @spec connect(String.t(), keyword()) :: {:ok, pid()} | {:error, error()}
  def connect(dsn, opts \\ []) when is_binary(dsn) do
    with {:ok, conn} <- Connection.start_link([dsn: dsn, owner: self()] ++ opts) do
      case Connection.handshake(conn) do
        :ok ->
          {:ok, conn}

        {:error, error} ->
          # Nothing usable came of it, so do not leave a process behind.
          Connection.close(conn)
          {:error, error}
      end
    end
  end

  @doc "Same as `connect/2`, but raises on failure."
  @spec connect!(String.t(), keyword()) :: pid()
  def connect!(dsn, opts \\ []), do: dsn |> connect(opts) |> bang!()

  @doc """
  Runs one statement and returns its first result set.

  `params` fills the statement's placeholders. A statement string holding
  several `;`-separated statements answers with the first one's result — use
  `execute_all/4` for the rest, and see there for `:multi_statement_count`,
  which such a string needs.

  Accepts a `:timeout` in milliseconds (or `:infinity`) for this statement
  alone; without one the connection's own applies.
  """
  @spec execute(conn(), String.t(), params(), keyword()) :: {:ok, Result.t()} | {:error, error()}
  def execute(conn, sql, params \\ [], opts \\ []) do
    case execute_all(conn, sql, params, opts) do
      {:ok, [result | _]} -> {:ok, result}
      {:ok, []} -> {:ok, %Result{}}
      {:error, error} -> {:error, error}
    end
  end

  @doc "Same as `execute/4`, but raises on failure."
  @spec execute!(conn(), String.t(), params(), keyword()) :: Result.t()
  def execute!(conn, sql, params \\ [], opts \\ []) do
    conn |> execute(sql, params, opts) |> bang!()
  end

  @doc """
  Runs a statement string and returns every result set it produced, in order.

  A single statement gives a one-element list. A string holding several
  statements declares how many with `:multi_statement_count` — the exact
  number, or `0` for any number:

      Frostlake.execute_all(conn, "SELECT 1; SELECT 2", [], multi_statement_count: 2)

  Without it the session's `MULTI_STATEMENT_COUNT` decides, which starts at 1,
  so the engine refuses the string before running any of it — the way
  Snowflake does. `ALTER SESSION SET MULTI_STATEMENT_COUNT = 0` lifts that for
  the rest of the session. Engines before 0.1.0 run any number and ignore the
  declaration.
  """
  @spec execute_all(conn(), String.t(), params(), keyword()) ::
          {:ok, [Result.t()]} | {:error, error()}
  def execute_all(conn, sql, params \\ [], opts \\ []) when is_binary(sql) do
    # With no parameters the markers are the server's and pass through verbatim;
    # the render still refuses a statement mixing the two placeholder styles.
    with {:ok, rendered} <- Connection.render(sql, params) do
      Connection.execute(conn, sql, rendered, opts)
    end
  end

  @doc "Same as `execute_all/4`, but raises on failure."
  @spec execute_all!(conn(), String.t(), params(), keyword()) :: [Result.t()]
  def execute_all!(conn, sql, params \\ [], opts \\ []) do
    conn |> execute_all(sql, params, opts) |> bang!()
  end

  @doc """
  Runs `fun` inside `BEGIN` … `COMMIT`, rolling back if it does not finish
  cleanly.

  The connection is handed to `fun`. It commits and answers `{:ok, value}` when
  `fun` returns; it rolls back and answers `{:error, reason}` when `fun` returns
  one; and it rolls back and re-raises when `fun` raises, throws or exits.

      Frostlake.transaction(conn, fn c ->
        Frostlake.execute!(c, "INSERT INTO acc VALUES (1)")
      end)

  The connection is *not* held for the duration: a transaction lives on the
  session, so anything else run on this same connection meanwhile joins it. Give
  a transaction its own connection if that is not what you want.
  """
  @spec transaction(conn(), (conn() -> value), keyword()) :: {:ok, value} | {:error, error()}
        when value: term()
  def transaction(conn, fun, opts \\ []) when is_function(fun, 1) do
    with :ok <- Connection.begin(conn, opts) do
      try do
        fun.(conn)
      catch
        kind, reason ->
          stacktrace = __STACKTRACE__
          # A failed rollback must not replace the error that caused it.
          _ = Connection.rollback(conn, opts)
          :erlang.raise(kind, reason, stacktrace)
      else
        {:error, _reason} = error ->
          _ = Connection.rollback(conn, opts)
          error

        value ->
          with :ok <- Connection.commit(conn, opts), do: {:ok, value}
      end
    end
  end

  @doc """
  Closes the connection.

  A statement already in flight finishes first. The HTTP API has no endpoint for
  ending a session, so the engine's own idle sweep is what reclaims the session
  behind it.
  """
  @spec close(conn()) :: :ok
  defdelegate close(conn), to: Connection

  @doc "Checks that a Frostlake engine is answering, via `GET /api/health`."
  @spec ping(conn(), keyword()) :: :ok | {:error, error()}
  defdelegate ping(conn, opts \\ []), to: Connection

  @doc "Opens a transaction: autocommit goes off and `BEGIN` is sent."
  @spec begin(conn(), keyword()) :: :ok | {:error, error()}
  defdelegate begin(conn, opts \\ []), to: Connection

  @doc "Commits the open transaction and restores autocommit."
  @spec commit(conn(), keyword()) :: :ok | {:error, error()}
  defdelegate commit(conn, opts \\ []), to: Connection

  @doc "Rolls the open transaction back and restores autocommit."
  @spec rollback(conn(), keyword()) :: :ok | {:error, error()}
  defdelegate rollback(conn, opts \\ []), to: Connection

  @doc "Selects the database, schema, role and warehouse the DSN names."
  @spec apply_scope(conn(), keyword()) :: :ok | {:error, error()}
  defdelegate apply_scope(conn, opts \\ []), to: Connection

  @doc "The engine's id for this connection's session, once it has one."
  @spec session_id(conn()) :: String.t() | nil
  defdelegate session_id(conn), to: Connection

  @doc "Whether a transaction is open on this connection."
  @spec in_transaction?(conn()) :: boolean()
  defdelegate in_transaction?(conn), to: Connection

  @doc "The configuration this connection was opened with."
  @spec config(conn()) :: Frostlake.Config.t()
  defdelegate config(conn), to: Connection

  @doc "Starts a connection process for a supervision tree; see `Frostlake.Connection`."
  @spec start_link(keyword()) :: GenServer.on_start()
  defdelegate start_link(opts), to: Connection

  @doc false
  defdelegate child_spec(opts), to: Connection

  defp bang!({:ok, value}), do: value
  defp bang!(:ok), do: :ok
  defp bang!({:error, error}), do: raise(error)
end
