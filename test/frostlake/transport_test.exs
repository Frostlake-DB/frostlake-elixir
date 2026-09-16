defmodule Frostlake.TransportTest do
  @moduledoc """
  What the driver does with answers a healthy engine never gives: a proxy's
  error page, a socket that closes between statements, a reply that never comes.

  These run against `Frostlake.FakeServer` rather than the engine, because a
  real one cannot be made to misbehave on cue.
  """

  use ExUnit.Case, async: true

  alias Frostlake.{ConnectionError, FakeServer, JSON, QueryError, UsageError}

  @health ~s({"status":"healthy","activeSessions":1})

  defp ok_body(opts \\ []) do
    JSON.encode(%{
      "success" => true,
      "sessionId" => Keyword.get(opts, :session, "s-1"),
      "resultSets" => [
        %{
          "columns" => [%{"name" => "N", "dataType" => "NUMBER", "precision" => 38, "scale" => 0}],
          "rows" => [[Keyword.get(opts, :value, 1)]],
          "rowCount" => 1
        }
      ]
    })
  end

  # Answers health with the engine's own payload and everything else with a
  # one-cell grid, unless the test's own handler says otherwise.
  defp server(handler) do
    {:ok, server} =
      FakeServer.start_link(fn request, index ->
        cond do
          request.path == "/api/health" -> {:reply, 200, @health}
          true -> handler.(request, index)
        end
      end)

    on_exit(fn -> FakeServer.stop(server) end)
    server
  end

  defp connect(server, opts \\ []) do
    Frostlake.connect(FakeServer.dsn(server), opts)
  end

  describe "recognising a Frostlake server" do
    test "a body that is not a Frostlake response names the address that answered" do
      {:ok, server} =
        FakeServer.start_link(fn _request, _index ->
          {:reply, 502, "<html>Bad Gateway</html>"}
        end)

      on_exit(fn -> FakeServer.stop(server) end)

      assert {:error, %ConnectionError{} = error} = connect(server)
      assert error.message =~ "/api/health"
      assert error.message =~ "not a Frostlake response"
      assert error.message =~ "Bad Gateway"
    end

    test "a health payload without a status is refused too, and quoted back" do
      {:ok, server} =
        FakeServer.start_link(fn _request, _index -> {:reply, 200, ~s({"ok":1})} end)

      on_exit(fn -> FakeServer.stop(server) end)

      assert {:error, %ConnectionError{} = error} = connect(server)
      assert error.status == 200
      assert error.message =~ ~s({"ok":1})
    end

    test "nothing listening on the port is reported as such" do
      {:ok, socket} = :gen_tcp.listen(0, [])
      {:ok, port} = :inet.port(socket)
      :gen_tcp.close(socket)

      assert {:error, %ConnectionError{} = error} =
               Frostlake.connect("frostlake://127.0.0.1:#{port}", connect_timeout: 2_000)

      assert error.message =~ "cannot reach"
    end
  end

  describe "answers" do
    test "a chunked response is read the same as a counted one" do
      server = server(fn _request, _index -> {:reply_chunked, 200, ok_body(value: 7)} end)

      {:ok, conn} = connect(server)
      assert {:ok, result} = Frostlake.execute(conn, "SELECT 7")
      assert result.rows == [[7]]
    end

    test "a failure with no message at all still says something" do
      server =
        server(fn _request, _index -> {:reply, 200, ~s({"success":false,"sessionId":"s"})} end)

      {:ok, conn} = connect(server)
      assert {:error, %QueryError{} = error} = Frostlake.execute(conn, "SELECT 1")
      assert error.message =~ "no error message"
    end

    test "the endpoint's own error field is used when there is no errorMessage" do
      # What POST /api/execute answers for a blank statement, before the engine
      # ever sees it.
      server = server(fn _request, _index -> {:reply, 400, ~s({"error":"SQL is required"})} end)

      {:ok, conn} = connect(server)
      assert {:error, %QueryError{} = error} = Frostlake.execute(conn, "  ")
      assert error.message == "SQL is required"
      assert error.status == 400
    end

    test "a query error carries the statement as it was sent" do
      server =
        server(fn _request, _index ->
          {:reply, 200, ~s({"success":false,"errorMessage":"Table X does not exist"})}
        end)

      {:ok, conn} = connect(server)
      assert {:error, %QueryError{} = error} = Frostlake.execute(conn, "SELECT ?", ["secret"])
      assert error.message == "Table X does not exist"
      assert error.statement == "SELECT 'secret'"
    end
  end

  describe "the session" do
    test "is carried on every statement after the first answer" do
      server = server(fn _request, _index -> {:reply, 200, ok_body(session: "sess-42")} end)

      {:ok, conn} = connect(server)
      {:ok, _} = Frostlake.execute(conn, "SELECT 1")
      {:ok, _} = Frostlake.execute(conn, "SELECT 2")

      assert Frostlake.session_id(conn) == "sess-42"

      [_health | executes] = FakeServer.requests(server)
      assert [first, second] = executes
      refute JSON.decode!(first.body)["sessionId"]
      assert JSON.decode!(second.body)["sessionId"] == "sess-42"
    end

    test "the DSN's scope is selected before the first statement" do
      server = server(fn _request, _index -> {:reply, 200, ok_body()} end)

      {:ok, conn} = connect(server, database: "DB", schema: "S", role: "R", warehouse: "W")
      {:ok, _} = Frostlake.execute(conn, "SELECT 1")

      statements =
        server
        |> FakeServer.requests()
        |> Enum.filter(&(&1.path == "/api/execute"))
        |> Enum.map(&JSON.decode!(&1.body)["sql"])

      assert statements == [
               ~s(USE ROLE "R"),
               ~s(USE WAREHOUSE "W"),
               ~s(USE DATABASE "DB"),
               ~s(USE SCHEMA "S"),
               "SELECT 1"
             ]
    end

    test "a scope that the server refuses keeps failing rather than running elsewhere" do
      server =
        server(fn request, _index ->
          if JSON.decode!(request.body)["sql"] =~ "USE DATABASE" do
            {:reply, 200, ~s({"success":false,"errorMessage":"Database MISSING does not exist"})}
          else
            {:reply, 200, ok_body()}
          end
        end)

      assert {:error, %QueryError{} = error} = connect(server, database: "MISSING")
      assert error.message =~ "does not exist"
    end

    test "is put back on the DSN's scope once it has been idle past the limit" do
      server = server(fn _request, _index -> {:reply, 200, ok_body()} end)

      {:ok, conn} = connect(server, database: "DB", idle_limit: 1)
      {:ok, _} = Frostlake.execute(conn, "SELECT 1")
      Process.sleep(20)
      {:ok, _} = Frostlake.execute(conn, "SELECT 2")

      statements = executed(server)
      assert statements == [~s(USE DATABASE "DB"), "SELECT 1", ~s(USE DATABASE "DB"), "SELECT 2"]
    end

    test "stops being put back once the caller has selected a scope themselves" do
      server = server(fn _request, _index -> {:reply, 200, ok_body()} end)

      {:ok, conn} = connect(server, database: "DB", idle_limit: 1)
      {:ok, _} = Frostlake.execute(conn, "USE DATABASE OTHER")
      Process.sleep(20)
      {:ok, _} = Frostlake.execute(conn, "SELECT 2")

      assert executed(server) == [~s(USE DATABASE "DB"), "USE DATABASE OTHER", "SELECT 2"]
    end

    test "autocommit goes off for the length of a transaction" do
      server = server(fn _request, _index -> {:reply, 200, ok_body()} end)

      {:ok, conn} = connect(server)

      {:ok, :ok} =
        Frostlake.transaction(conn, fn c ->
          assert Frostlake.in_transaction?(c)
          {:ok, _} = Frostlake.execute(c, "INSERT INTO t VALUES (1)")
          :ok
        end)

      refute Frostlake.in_transaction?(conn)

      flags =
        server
        |> FakeServer.requests()
        |> Enum.filter(&(&1.path == "/api/execute"))
        |> Enum.map(&{JSON.decode!(&1.body)["sql"], JSON.decode!(&1.body)["autoCommit"]})

      assert flags == [
               {"BEGIN", false},
               {"INSERT INTO t VALUES (1)", false},
               {"COMMIT", false}
             ]
    end

    test "a body that raises rolls back and re-raises" do
      server = server(fn _request, _index -> {:reply, 200, ok_body()} end)
      {:ok, conn} = connect(server)

      assert_raise RuntimeError, "boom", fn ->
        Frostlake.transaction(conn, fn _c -> raise "boom" end)
      end

      assert executed(server) == ["BEGIN", "ROLLBACK"]
      refute Frostlake.in_transaction?(conn)
    end

    test "a body that answers an error rolls back and reports it" do
      server = server(fn _request, _index -> {:reply, 200, ok_body()} end)
      {:ok, conn} = connect(server)

      assert {:error, :nope} = Frostlake.transaction(conn, fn _c -> {:error, :nope} end)
      assert executed(server) == ["BEGIN", "ROLLBACK"]
    end
  end

  describe "a socket that does not survive between statements" do
    test "is replaced silently when the server dropped it after answering" do
      # What the engine's own idle sweep looks like from here: the answer said
      # keep-alive, and the socket went away anyway. Each statement still runs
      # exactly once, on a socket of its own.
      server = server(fn _request, _index -> {:reply_then_drop, 200, ok_body()} end)

      {:ok, conn} = connect(server)
      assert {:ok, _} = Frostlake.execute(conn, "SELECT 1")
      assert {:ok, _} = Frostlake.execute(conn, "SELECT 2")
      assert executed(server) == ["SELECT 1", "SELECT 2"]
    end

    test "is not re-sent once the request has gone out" do
      # The server read the statement and then died without answering. It may
      # have run: an INSERT whose fate is unknown must not be repeated.
      server = server(fn _request, _index -> :close end)

      {:ok, conn} = connect(server)
      assert {:error, %ConnectionError{}} = Frostlake.execute(conn, "INSERT INTO t VALUES (1)")
      assert executed(server) == ["INSERT INTO t VALUES (1)"]
    end

    test "is not re-sent once the server has begun to answer" do
      server = server(fn _request, _index -> :half_answer end)

      {:ok, conn} = connect(server)
      assert {:error, %ConnectionError{}} = Frostlake.execute(conn, "INSERT INTO t VALUES (1)")
      assert executed(server) == ["INSERT INTO t VALUES (1)"]
    end

    test "a connection: close answer is honoured, and the next statement opens a new socket" do
      server = server(fn _request, _index -> {:reply_and_close, 200, ok_body()} end)

      {:ok, conn} = connect(server)
      assert {:ok, _} = Frostlake.execute(conn, "SELECT 1")
      assert {:ok, _} = Frostlake.execute(conn, "SELECT 2")
      assert executed(server) == ["SELECT 1", "SELECT 2"]
    end
  end

  describe "deadlines" do
    test "a statement that is never answered fails with the limit in the message" do
      server = server(fn _request, _index -> :hang end)

      {:ok, conn} = connect(server, timeout: 150)
      assert {:error, %ConnectionError{} = error} = Frostlake.execute(conn, "SELECT 1")
      assert error.message =~ "did not answer within 150ms"
      assert error.reason == :timeout
    end

    test "a per-statement timeout outranks the connection's" do
      server =
        server(fn request, _index ->
          if JSON.decode!(request.body)["sql"] == "SELECT 1",
            do: :hang,
            else: {:reply, 200, ok_body()}
        end)

      {:ok, conn} = connect(server, timeout: 60_000)
      assert {:error, %ConnectionError{}} = Frostlake.execute(conn, "SELECT 1", [], timeout: 100)
      assert {:ok, _} = Frostlake.execute(conn, "SELECT 2")
    end

    test "a timeout that is not one is a usage error, and leaves the connection alive" do
      server = server(fn _request, _index -> {:reply, 200, ok_body()} end)
      {:ok, conn} = connect(server)

      assert {:error, %UsageError{}} = Frostlake.execute(conn, "SELECT 1", [], timeout: "soon")
      assert {:ok, _} = Frostlake.execute(conn, "SELECT 1")
    end
  end

  describe "the statement count" do
    test "travels only when declared, and only with the caller's statement" do
      server = server(fn _request, _index -> {:reply, 200, ok_body()} end)
      {:ok, conn} = connect(server, database: "DB")

      {:ok, _} = Frostlake.execute_all(conn, "SELECT 1; SELECT 2", [], multi_statement_count: 2)
      {:ok, _} = Frostlake.execute(conn, "SELECT 3; SELECT 4", [], multi_statement_count: 0)
      {:ok, _} = Frostlake.execute(conn, "SELECT 5")

      counts =
        server
        |> FakeServer.requests()
        |> Enum.filter(&(&1.path == "/api/execute"))
        |> Enum.map(fn request ->
          body = JSON.decode!(request.body)
          {body["sql"], Map.fetch(body, "multiStatementCount")}
        end)

      assert counts == [
               {~s(USE DATABASE "DB"), :error},
               {"SELECT 1; SELECT 2", {:ok, 2}},
               {"SELECT 3; SELECT 4", {:ok, 0}},
               {"SELECT 5", :error}
             ]
    end

    test "that is not a count is a usage error, and nothing is sent" do
      server = server(fn _request, _index -> {:reply, 200, ok_body()} end)
      {:ok, conn} = connect(server)

      for bad <- [-1, 1.5, "2", :any] do
        assert {:error, %UsageError{} = error} =
                 Frostlake.execute_all(conn, "SELECT 1; SELECT 2", [], multi_statement_count: bad)

        assert error.message =~ ":multi_statement_count"
      end

      assert executed(server) == []
      assert {:ok, _} = Frostlake.execute(conn, "SELECT 1")
    end
  end

  describe "the connection process" do
    test "serializes statements from several callers onto one session" do
      server = server(fn _request, _index -> {:reply, 200, ok_body()} end)
      {:ok, conn} = connect(server)

      tasks =
        for n <- 1..8 do
          Task.async(fn -> Frostlake.execute(conn, "SELECT #{n}") end)
        end

      assert Enum.all?(Task.await_many(tasks), &match?({:ok, _}, &1))
      assert length(executed(server)) == 8
    end

    test "a closed connection says so rather than opening a second session" do
      server = server(fn _request, _index -> {:reply, 200, ok_body()} end)
      {:ok, conn} = connect(server)

      assert :ok = Frostlake.close(conn)

      assert {:error, %UsageError{message: "the connection is closed"}} =
               Frostlake.execute(conn, "SELECT 1")

      assert :ok = Frostlake.close(conn)
    end

    test "runs under a supervisor, applying the DSN's scope before the first statement" do
      server = server(fn _request, _index -> {:reply, 200, ok_body()} end)

      start_supervised!(
        {Frostlake.Connection,
         dsn: FakeServer.dsn(server), database: "DB", name: :supervised_conn}
      )

      assert {:ok, _} = Frostlake.execute(:supervised_conn, "SELECT 1")
      assert executed(server) == [~s(USE DATABASE "DB"), "SELECT 1"]
    end
  end

  defp executed(server) do
    server
    |> FakeServer.requests()
    |> Enum.filter(&(&1.path == "/api/execute"))
    |> Enum.map(&JSON.decode!(&1.body)["sql"])
  end
end
