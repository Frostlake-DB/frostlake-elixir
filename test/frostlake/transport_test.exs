defmodule Frostlake.TransportTest do
  @moduledoc """
  What the driver does with answers a healthy engine never gives: a proxy's
  error page, a socket that closes between statements, a reply that never comes.

  These run against `Frostlake.FakeServer` rather than the engine, because a
  real one cannot be made to misbehave on cue.
  """

  use ExUnit.Case, async: true

  alias Frostlake.{ConnectionError, FakeServer, JSON, QueryError, SessionLostError, UsageError}

  @health ~s({"status":"healthy","activeSessions":1})

  # Without :new_session the answer is an engine before 0.1.0's, which never
  # marks one.
  defp ok_body(opts \\ []) do
    body = %{
      "success" => true,
      "sessionId" => Keyword.get(opts, :session, "s-1"),
      "resultSets" => [
        %{
          "columns" => [%{"name" => "N", "dataType" => "NUMBER", "precision" => 38, "scale" => 0}],
          "rows" => [[Keyword.get(opts, :value, 1)]],
          "rowCount" => 1
        }
      ]
    }

    body =
      case Keyword.fetch(opts, :new_session) do
        {:ok, mark} -> Map.put(body, "newSession", mark)
        :error -> body
      end

    JSON.encode(body)
  end

  # Answers the way engine 0.1.0 does. Every answer says whether the statement
  # ran in a session started for it — always so for a request naming none, and
  # so for any request `replaced?` picks, as though the session had been reaped
  # just before it arrived. A release is answered with `release`.
  defp engine_010(replaced? \\ fn _sql, _index -> false end, release \\ nil) do
    server(fn request, index ->
      if request.method == "DELETE" do
        release || {:reply, 200, ~s({"success":true,"sessionId":null,"newSession":false})}
      else
        body = JSON.decode!(request.body)
        fresh = body["sessionId"] == nil or replaced?.(body["sql"], index)
        {:reply, 200, ok_body(new_session: fresh)}
      end
    end)
  end

  # Answers the way engine 0.1.0 does when it is sent `requireSession`: a request
  # naming a session that `gone?` picks is refused with the engine's 404, as
  # though the session had been reaped just before it arrived, and nothing runs.
  # A request naming no session starts one, named after the request's number.
  defp engine_requiring(gone? \\ fn _body, _index -> false end) do
    server(fn request, index ->
      if request.method == "DELETE" do
        {:reply, 200, ~s({"success":true,"sessionId":null,"newSession":false})}
      else
        body = JSON.decode!(request.body)
        sent = body["sessionId"]

        if sent != nil and gone?.(body, index) do
          {:reply, 404,
           JSON.encode(%{
             "success" => false,
             "sessionId" => nil,
             "newSession" => false,
             "errorMessage" => "Session '#{sent}' does not exist or has expired."
           })}
        else
          {:reply, 200, ok_body(session: sent || "s-#{index}", new_session: sent == nil)}
        end
      end
    end)
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

    test "is put back on the DSN's scope once the engine says it replaced it" do
      server = engine_010(fn sql, _index -> sql == "SELECT 1" end)

      {:ok, conn} = connect(server, database: "DB")
      {:ok, _} = Frostlake.execute(conn, "SELECT 1")
      {:ok, _} = Frostlake.execute(conn, "SELECT 2")
      {:ok, _} = Frostlake.execute(conn, "SELECT 3")

      # The USE met a new session too, as the first request always does; only
      # SELECT 1 met a replacement, and it has already run by then.
      assert executed(server) == [
               ~s(USE DATABASE "DB"),
               "SELECT 1",
               ~s(USE DATABASE "DB"),
               "SELECT 2",
               "SELECT 3"
             ]
    end

    test "is put back on the DSN's scope after a replacement, whatever the caller had selected" do
      # The caller's USE lived in the session the engine replaced, so it no
      # longer keeps the DSN's scope off. A pause past the idle limit comes
      # before every statement, and changes nothing: an engine that marks
      # `newSession` is not second-guessed by the idle check.
      server = engine_010(fn sql, _index -> sql == "SELECT 1" end)
      {:ok, conn} = connect(server, database: "DB", idle_limit: 1)

      for sql <- ["USE DATABASE OTHER", "SELECT 1", "SELECT 2", "SELECT 3"] do
        Process.sleep(20)
        {:ok, _} = Frostlake.execute(conn, sql)
      end

      assert executed(server) == [
               ~s(USE DATABASE "DB"),
               "USE DATABASE OTHER",
               "SELECT 1",
               ~s(USE DATABASE "DB"),
               "SELECT 2",
               "SELECT 3"
             ]
    end

    test "a USE that meets a replaced session gives way to the DSN's scope" do
      # It ran in the new session, before the DSN's scope went back on over it;
      # the scope is the DSN's again. As above, a pause past the idle limit
      # comes before every statement, and the idle check stays out of it.
      server = engine_010(fn sql, _index -> sql == "USE DATABASE OTHER" end)
      {:ok, conn} = connect(server, database: "DB", idle_limit: 1)

      for sql <- ["USE DATABASE OTHER", "SELECT 1", "SELECT 2"] do
        Process.sleep(20)
        {:ok, _} = Frostlake.execute(conn, sql)
      end

      assert executed(server) == [
               ~s(USE DATABASE "DB"),
               "USE DATABASE OTHER",
               ~s(USE DATABASE "DB"),
               "SELECT 1",
               "SELECT 2"
             ]
    end

    test "a replacement met part-way through the scope puts all of it back on" do
      # The session goes between the scope's two USE statements when it is
      # applied again, taking the role with it.
      server = engine_010(fn _sql, index -> index == 5 end)

      {:ok, conn} = connect(server, role: "R", database: "DB")
      assert :ok = Frostlake.apply_scope(conn)
      {:ok, _} = Frostlake.execute(conn, "SELECT 1")

      assert executed(server) == [
               ~s(USE ROLE "R"),
               ~s(USE DATABASE "DB"),
               ~s(USE ROLE "R"),
               ~s(USE DATABASE "DB"),
               ~s(USE ROLE "R"),
               ~s(USE DATABASE "DB"),
               "SELECT 1"
             ]
    end

    test "an engine that replaces the session on every request cannot keep the scope going round" do
      server = engine_010(fn _sql, _index -> true end)

      {:ok, conn} = connect(server, role: "R", database: "DB")
      {:ok, _} = Frostlake.execute(conn, "SELECT 1")
      {:ok, _} = Frostlake.execute(conn, "SELECT 2")

      scope = [~s(USE ROLE "R"), ~s(USE DATABASE "DB")]
      assert executed(server) == scope ++ scope ++ ["SELECT 1"] ++ scope ++ scope ++ ["SELECT 2"]
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

  describe "a lost session" do
    test "requireSession is sent only once the engine has shown it marks newSession" do
      server = engine_requiring()
      {:ok, conn} = connect(server, database: "DB")
      {:ok, _} = Frostlake.execute(conn, "SELECT 1")

      # The first request names no session, so there is nothing to require yet;
      # its answer is what says the engine can take the field.
      assert [
               %{"sql" => ~s(USE DATABASE "DB")} = first,
               %{"sql" => "SELECT 1", "sessionId" => "s-2", "requireSession" => true}
             ] = bodies(server)

      refute Map.has_key?(first, "sessionId")
      refute Map.has_key?(first, "requireSession")
    end

    test "an engine from before 0.1.0 is never sent requireSession" do
      old = server(fn _request, _index -> {:reply, 200, ok_body()} end)
      {:ok, conn} = connect(old, database: "DB")
      {:ok, _} = Frostlake.execute(conn, "SELECT 1")
      {:ok, _} = Frostlake.execute(conn, "SELECT 2")

      assert Enum.all?(bodies(old), &(not Map.has_key?(&1, "requireSession")))
      assert List.last(bodies(old))["sessionId"] == "s-1"
    end

    test "is replaced on the DSN's scope, and the statement is sent once more" do
      server = engine_requiring(fn body, _index -> body["sessionId"] == "s-2" end)
      {:ok, conn} = connect(server, database: "DB")

      assert {:ok, [result]} = Frostlake.execute_all(conn, "SELECT 1")
      assert result.rows == [[1]]

      assert executed(server) == [
               ~s(USE DATABASE "DB"),
               "SELECT 1",
               ~s(USE DATABASE "DB"),
               "SELECT 1"
             ]

      # The lost id is dropped: the scope starts a fresh session, and the
      # statement runs in it.
      [_, _, rescope, resent] = bodies(server)
      refute Map.has_key?(rescope, "sessionId")
      assert resent["sessionId"] == "s-4"
      assert resent["requireSession"] == true
      assert Frostlake.session_id(conn) == "s-4"
    end

    test "a second refusal is reported, and the connection carries on" do
      server =
        engine_requiring(fn body, _index ->
          body["sql"] == "SELECT 1" and body["sessionId"] in ["s-2", "s-4"]
        end)

      {:ok, conn} = connect(server, database: "DB")

      assert {:error, %SessionLostError{} = error} = Frostlake.execute(conn, "SELECT 1")
      assert error.message =~ "just started"
      assert error.statement == "SELECT 1"

      assert {:ok, _} = Frostlake.execute(conn, "SELECT 2")
      assert Enum.take(executed(server), -2) == [~s(USE DATABASE "DB"), "SELECT 2"]
    end

    test "with a transaction open is reported, and nothing is sent again" do
      server = engine_requiring(fn body, _index -> body["sql"] =~ "INSERT" end)
      {:ok, conn} = connect(server, database: "DB")

      assert :ok = Frostlake.begin(conn)

      assert {:error, %SessionLostError{} = error} =
               Frostlake.execute(conn, "INSERT INTO t VALUES (1)")

      assert error.message =~ "transaction"
      assert error.message =~ "did not run"
      refute Frostlake.in_transaction?(conn)
      assert Frostlake.session_id(conn) == nil
      assert executed(server) == [~s(USE DATABASE "DB"), "BEGIN", "INSERT INTO t VALUES (1)"]

      # The transaction went with its session: a commit says so, and sends nothing.
      assert {:error, %SessionLostError{}} = Frostlake.commit(conn)
      assert length(executed(server)) == 3

      # The next statement starts over on the DSN's scope, in autocommit.
      {:ok, _} = Frostlake.execute(conn, "SELECT 1")

      assert [{~s(USE DATABASE "DB"), true}, {"SELECT 1", true}] =
               server |> bodies() |> Enum.take(-2) |> Enum.map(&{&1["sql"], &1["autoCommit"]})
    end

    test "with a transaction open fails the transaction helper, even when the body shrugs it off" do
      server = engine_requiring(fn body, _index -> body["sql"] =~ "INSERT" end)
      {:ok, conn} = connect(server, database: "DB")

      assert {:error, %SessionLostError{}} =
               Frostlake.transaction(conn, fn c ->
                 _ignored = Frostlake.execute(c, "INSERT INTO t VALUES (1)")
                 :done
               end)

      # Neither a COMMIT nor a ROLLBACK went to a fresh session.
      assert executed(server) == [~s(USE DATABASE "DB"), "BEGIN", "INSERT INTO t VALUES (1)"]
    end

    test "rolling back a transaction that went with its session answers :ok and sends nothing" do
      server = engine_requiring(fn body, _index -> body["sql"] =~ "INSERT" end)
      {:ok, conn} = connect(server, database: "DB")

      assert {:error, %SessionLostError{}} =
               Frostlake.transaction(conn, fn c ->
                 Frostlake.execute(c, "INSERT INTO t VALUES (1)")
               end)

      # The helper's rollback answered :ok without a request of its own.
      assert executed(server) == [~s(USE DATABASE "DB"), "BEGIN", "INSERT INTO t VALUES (1)"]
    end

    test "with a transaction begun in SQL is reported too" do
      for begin <- ["BEGIN", "begin transaction", "START TRANSACTION"] do
        server = engine_requiring(fn body, _index -> body["sql"] == "SELECT 1" end)
        {:ok, conn} = connect(server, database: "DB")
        {:ok, _} = Frostlake.execute(conn, begin)

        assert {:error, %SessionLostError{} = error} = Frostlake.execute(conn, "SELECT 1")
        assert error.message =~ "transaction"
        assert executed(server) == [~s(USE DATABASE "DB"), begin, "SELECT 1"]
      end
    end

    test "whose context moved is reported, and the next statement starts over" do
      moves = [
        "USE SCHEMA OTHER",
        "SET X = 1",
        "UNSET X",
        "ALTER SESSION SET TIMEZONE = 'UTC'",
        "CREATE TEMPORARY TABLE T (A INT)",
        "CREATE SCHEMA OTHER",
        "DROP DATABASE OTHER"
      ]

      for move <- moves do
        server = engine_requiring(fn body, _index -> body["sql"] == "SELECT * FROM T" end)
        {:ok, conn} = connect(server, database: "DB")
        {:ok, _} = Frostlake.execute(conn, move)

        assert {:error, %SessionLostError{} = error} = Frostlake.execute(conn, "SELECT * FROM T")
        assert error.message =~ "context"
        assert error.message =~ "not re-run"
        assert executed(server) == [~s(USE DATABASE "DB"), move, "SELECT * FROM T"]

        {:ok, _} = Frostlake.execute(conn, "SELECT 1")
        assert Enum.take(executed(server), -2) == [~s(USE DATABASE "DB"), "SELECT 1"]
      end
    end

    test "a move anywhere in a request counts" do
      server = engine_requiring(fn body, _index -> body["sql"] == "SELECT 2" end)
      {:ok, conn} = connect(server, database: "DB")

      {:ok, _} =
        Frostlake.execute(conn, "SELECT 1; USE SCHEMA OTHER", [], multi_statement_count: 2)

      assert {:error, %SessionLostError{}} = Frostlake.execute(conn, "SELECT 2")
    end

    test "after a committed transaction is replaced like any other" do
      server =
        engine_requiring(fn body, _index ->
          body["sql"] == "SELECT 1" and body["sessionId"] == "s-2"
        end)

      {:ok, conn} = connect(server, database: "DB")

      {:ok, :ok} =
        Frostlake.transaction(conn, fn c ->
          {:ok, _} = Frostlake.execute(c, "INSERT INTO t VALUES (1)")
          :ok
        end)

      assert {:ok, _} = Frostlake.execute(conn, "SELECT 1")

      assert executed(server) == [
               ~s(USE DATABASE "DB"),
               "BEGIN",
               "INSERT INTO t VALUES (1)",
               "COMMIT",
               "SELECT 1",
               ~s(USE DATABASE "DB"),
               "SELECT 1"
             ]
    end

    test "a transaction the engine replaced the session under cannot be committed" do
      # An engine that marks newSession but still replaces a session it was told
      # to require: whatever answer brings the news, the transaction is gone.
      for replaced <- ["INSERT INTO t VALUES (1)", "COMMIT"] do
        server = engine_010(fn sql, _index -> sql == replaced end)
        {:ok, conn} = connect(server)
        assert :ok = Frostlake.begin(conn)
        {:ok, _} = Frostlake.execute(conn, "INSERT INTO t VALUES (1)")

        assert {:error, %SessionLostError{} = error} = Frostlake.commit(conn), replaced
        assert error.message =~ "nothing in it was committed"
        refute Frostlake.in_transaction?(conn)
      end
    end

    test "the idle check stays out of an engine that marks newSession" do
      server = engine_requiring()
      {:ok, conn} = connect(server, database: "DB", idle_limit: 1)
      Process.sleep(20)
      {:ok, _} = Frostlake.execute(conn, "SELECT 1")

      assert executed(server) == [~s(USE DATABASE "DB"), "SELECT 1"]
    end
  end

  describe "closing" do
    test "hands the session back to an engine that can take it, once" do
      server = engine_010()
      {:ok, conn} = connect(server)
      {:ok, _} = Frostlake.execute(conn, "SELECT 1")

      assert :ok = Frostlake.close(conn)
      assert :ok = Frostlake.close(conn)
      assert released(server) == ["/api/sessions/s-1"]
    end

    test "hands the session back when the process that opened it ends" do
      server = engine_010()
      test = self()

      spawn(fn ->
        {:ok, conn} = connect(server)
        {:ok, _} = Frostlake.execute(conn, "SELECT 1")
        send(test, {:opened, conn})
      end)

      assert_receive {:opened, conn}, 5_000
      ref = Process.monitor(conn)
      assert_receive {:DOWN, ^ref, :process, ^conn, _reason}, 10_000
      assert released(server) == ["/api/sessions/s-1"]
    end

    test "asks nothing of an engine from before 0.1.0, nor of one that never started a session" do
      old = server(fn _request, _index -> {:reply, 200, ok_body()} end)
      {:ok, conn} = connect(old)
      {:ok, _} = Frostlake.execute(conn, "SELECT 1")
      assert :ok = Frostlake.close(conn)
      assert released(old) == []

      # No scope and no statement: nothing ever named a session.
      new = engine_010()
      {:ok, conn} = connect(new)
      assert :ok = Frostlake.close(conn)
      assert released(new) == []
    end

    test "succeeds whatever the release meets, and does not wait past the connection's timeout" do
      gone = ~s({"success":false,"sessionId":null,"errorMessage":"Session 's-1' does not exist"})

      for answer <- [{:reply, 404, gone}, {:reply, 405, ""}, :close, :hang] do
        server = engine_010(fn _sql, _index -> false end, answer)
        {:ok, conn} = connect(server, timeout: 1_000)
        {:ok, _} = Frostlake.execute(conn, "SELECT 1")

        # The release is capped at five seconds; this connection allows one.
        {elapsed, :ok} = :timer.tc(fn -> Frostlake.close(conn) end)
        assert elapsed < 4_000_000, "#{inspect(answer)} held close/1 for #{elapsed}µs"
        assert released(server) == ["/api/sessions/s-1"]
      end

      # And with nothing left to answer at all.
      server = engine_010()
      {:ok, conn} = connect(server)
      {:ok, _} = Frostlake.execute(conn, "SELECT 1")
      FakeServer.stop(server)
      assert :ok = Frostlake.close(conn)
    end
  end

  defp executed(server) do
    server
    |> FakeServer.requests()
    |> Enum.filter(&(&1.path == "/api/execute"))
    |> Enum.map(&JSON.decode!(&1.body)["sql"])
  end

  defp bodies(server) do
    server
    |> FakeServer.requests()
    |> Enum.filter(&(&1.path == "/api/execute"))
    |> Enum.map(&JSON.decode!(&1.body))
  end

  defp released(server) do
    for %{method: "DELETE", path: path} <- FakeServer.requests(server), do: path
  end
end
