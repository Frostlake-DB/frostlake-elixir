defmodule Frostlake.TestServer do
  @moduledoc """
  A real `DatabaseHttpServer`, booted from an engine classpath for the tests
  that need one.

  Nothing here is mocked: every statement the integration tests run travels the
  driver's own HTTP path to a live engine. Without `FROSTLAKE_CLASSPATH` there is
  no server, and the tests that need one are excluded rather than passing on a
  stub — a green run that never reached an engine would be worse than a skipped
  one.

      JAVA_HOME=/path/to/jdk17 FROSTLAKE_CLASSPATH="engine/classes;deps/*" mix test
  """

  use GenServer

  @name __MODULE__
  @boot_timeout 60_000

  @doc """
  Starts the one server the whole test run shares, or says why it cannot.
  """
  @spec start_shared() :: :ok | {:skip, String.t()}
  def start_shared do
    case classpath() do
      nil ->
        {:skip, "FROSTLAKE_CLASSPATH is not set, so no engine can be started"}

      classpath ->
        case GenServer.start(__MODULE__, classpath, name: @name) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:skip, "the engine did not start: #{inspect(reason)}"}
        end
    end
  end

  @doc "A DSN pointing at the shared server, with no database or schema selected."
  @spec dsn() :: String.t()
  def dsn, do: GenServer.call(@name, :dsn)

  @doc """
  Stops the shared server, if one was started.

  The JVM is killed by pid rather than only through the process that owns it: a
  server whose own process has already died must not leave a JVM behind holding
  a port and a core.
  """
  @spec stop() :: :ok
  def stop do
    if Process.whereis(@name), do: GenServer.stop(@name, :normal, 30_000)
    kill(:persistent_term.get({__MODULE__, :os_pid}, nil))
    :ok
  catch
    :exit, _ -> :ok
  end

  defp classpath do
    case System.get_env("FROSTLAKE_CLASSPATH") do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  @impl true
  def init(classpath) do
    Process.flag(:trap_exit, true)
    port = free_port()

    # A default-configured engine persists its catalog under ~/.frostlake_engine
    # and its internal stages under ~/.frostlake_stages, so consecutive runs
    # would inherit each other's warehouses, stages and tables — and would walk
    # over whatever engine the developer runs for themselves. Everything is
    # pinned to a directory of this run's own instead, emptied before boot, so
    # every run starts on a clean catalog.
    home = Path.expand("_build/engine-#{port}", File.cwd!())
    File.rm_rf!(home)
    File.mkdir_p!(home)
    log = Path.join(home, "server.log")

    executable = java()

    erlang_port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        cd: String.to_charlist(home),
        env: [{~c"SQL_ENGINE_DATA_DIR", String.to_charlist(Path.join(home, "data"))}],
        args: [
          "-Duser.home=#{home}",
          "-cp",
          classpath,
          "dev.frostlake.http.DatabaseHttpServer",
          Integer.to_string(port)
        ]
      ])

    {:os_pid, os_pid} = Port.info(erlang_port, :os_pid)
    :persistent_term.put({__MODULE__, :os_pid}, os_pid)

    state = %{
      port: erlang_port,
      os_pid: os_pid,
      http_port: port,
      dsn: "frostlake://127.0.0.1:#{port}",
      log: File.open!(log, [:write, :binary]),
      log_path: log
    }

    case await_health(port, System.monotonic_time(:millisecond) + @boot_timeout, state) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:stop, {:engine_did_not_start, reason, log}}
    end
  end

  @impl true
  def handle_call(:dsn, _from, state), do: {:reply, state.dsn, state}

  @impl true
  # The engine's own output goes to a file: a full pipe would block the server,
  # and the log is what says why a boot failed anyway.
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    IO.binwrite(state.log, data)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    # Said once, loudly: every later engine-backed test fails on a dead server,
    # and the failure that explains them all is this one.
    IO.puts(:stderr, "\n*** the Frostlake engine exited with status #{status}; see #{state.log_path}")
    {:stop, {:engine_exited, status}, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Closing the Erlang port closes the JVM's stdin, which it ignores; the OS
    # process is what has to be told.
    kill(state.os_pid)
    _ = File.close(state.log)
    :ok
  end

  defp kill(nil), do: :ok

  defp kill(os_pid) do
    case :os.type() do
      {:win32, _} ->
        System.cmd("taskkill", ["/F", "/T", "/PID", Integer.to_string(os_pid)],
          stderr_to_stdout: true
        )

      _ ->
        System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end
  catch
    _, _ -> :ok
  end

  defp java do
    case System.get_env("JAVA_HOME") do
      home when is_binary(home) and home != "" -> Path.join([home, "bin", "java"])
      _ -> "java"
    end
    |> System.find_executable()
    |> case do
      nil -> raise "no java executable found; set JAVA_HOME"
      path -> path
    end
  end

  # Bind port 0 to have the OS name a free one, then hand it straight to the
  # engine. A race is possible in principle and has never been the problem in
  # practice; picking a fixed port collides with a developer's own server.
  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp await_health(port, deadline, state) do
    receive do
      {erlang_port, {:data, data}} when erlang_port == state.port ->
        IO.binwrite(state.log, data)
        await_health(port, deadline, state)

      {erlang_port, {:exit_status, status}} when erlang_port == state.port ->
        {:error, {:exited, status}}
    after
      100 ->
        cond do
          healthy?(port) -> {:ok, state}
          System.monotonic_time(:millisecond) > deadline -> {:error, :timeout}
          true -> await_health(port, deadline, state)
        end
    end
  end

  defp healthy?(port) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw], 1000) do
      {:ok, socket} ->
        request = "GET /api/health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
        :gen_tcp.send(socket, request)
        answer = :gen_tcp.recv(socket, 0, 5000)
        :gen_tcp.close(socket)

        match?({:ok, <<"HTTP/1.1 200", _::binary>>}, answer)

      {:error, _reason} ->
        false
    end
  end
end
