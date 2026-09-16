defmodule Frostlake.ConnectionTest do
  @moduledoc """
  The driver against a real `DatabaseHttpServer`: every statement here travels
  `connect` → HTTP → engine. Without `FROSTLAKE_CLASSPATH` the whole module is
  excluded rather than passing on a stub.
  """

  use ExUnit.Case, async: false

  @moduletag :server

  alias Frostlake.{QueryError, Result, TestServer, UsageError}

  setup do
    {:ok, conn} = Frostlake.connect(TestServer.dsn())
    on_exit(fn -> Frostlake.close(conn) end)

    database = "elixir_test_db"
    {:ok, _} = Frostlake.execute(conn, "CREATE OR REPLACE DATABASE #{database}")
    {:ok, _} = Frostlake.execute(conn, "USE DATABASE #{database}")
    {:ok, _} = Frostlake.execute(conn, "CREATE OR REPLACE SCHEMA test_schema")
    {:ok, _} = Frostlake.execute(conn, "USE SCHEMA test_schema")

    %{conn: conn}
  end

  describe "connecting" do
    test "answers the engine's own version", %{conn: conn} do
      assert {:ok, result} = Frostlake.execute(conn, "SELECT CURRENT_VERSION()")
      assert is_binary(Result.value(result))
    end

    test "ping reaches the health endpoint", %{conn: conn} do
      assert :ok = Frostlake.ping(conn)
    end

    test "a session id arrives with the first answer and stays", %{conn: conn} do
      assert is_binary(Frostlake.session_id(conn))
      first = Frostlake.session_id(conn)
      {:ok, _} = Frostlake.execute(conn, "SELECT 1")
      assert Frostlake.session_id(conn) == first
    end

    test "a database that does not exist is reported at connect time" do
      assert {:error, %QueryError{} = error} =
               Frostlake.connect(TestServer.dsn(), database: "no_such_database_here")

      assert error.message =~ "does not exist" or error.message =~ "not found"
    end

    test "the DSN's database and schema are selected" do
      {:ok, _} = Frostlake.execute(spare_connection(), "CREATE OR REPLACE DATABASE dsn_scope_db")

      {:ok, conn} =
        Frostlake.connect(TestServer.dsn(), database: "dsn_scope_db", schema: "public")

      on_exit(fn -> Frostlake.close(conn) end)

      assert {:ok, result} =
               Frostlake.execute(conn, "SELECT CURRENT_DATABASE(), CURRENT_SCHEMA()")

      assert result.rows == [["DSN_SCOPE_DB", "PUBLIC"]]
    end

    test "a quoted DSN name selects the object of exactly that case, from engine 0.1.0 on",
         %{conn: conn} do
      # Earlier engines fold a quoted name as well, so there is no lower-case
      # object to select.
      if engine_version(conn) >= {0, 1, 0} do
        {:ok, _} =
          Frostlake.execute(spare_connection(), ~s(CREATE OR REPLACE DATABASE "dsn_exact_db"))

        {:ok, exact} = Frostlake.connect(TestServer.dsn(), database: ~s("dsn_exact_db"))
        on_exit(fn -> Frostlake.close(exact) end)

        assert {:ok, result} = Frostlake.execute(exact, "SELECT CURRENT_DATABASE()")
        assert Result.value(result) == "dsn_exact_db"
      end
    end
  end

  describe "statements" do
    test "a DML answer carries an update count and the counters behind it", %{conn: conn} do
      {:ok, _} = Frostlake.execute(conn, "CREATE TABLE people (id INTEGER, name VARCHAR)")

      assert {:ok, inserted} =
               Frostlake.execute(conn, "INSERT INTO people VALUES (?, ?), (?, ?)", [
                 1,
                 "Ada",
                 2,
                 "Grace"
               ])

      assert inserted.update_count == 2
      assert Result.update?(inserted)
      assert inserted.counters == %{"number of rows inserted" => 2}

      assert {:ok, updated} =
               Frostlake.execute(conn, "UPDATE people SET name = ? WHERE id = ?", ["Ada L.", 1])

      assert updated.update_count == 1

      assert {:ok, deleted} = Frostlake.execute(conn, "DELETE FROM people WHERE id = 2")
      assert deleted.update_count == 1
    end

    test "a query answers a grid, keyed or positional", %{conn: conn} do
      {:ok, _} = Frostlake.execute(conn, "CREATE TABLE people (id INTEGER, name VARCHAR)")
      {:ok, _} = Frostlake.execute(conn, "INSERT INTO people VALUES (1, 'Ada'), (2, 'Grace')")

      assert {:ok, result} = Frostlake.execute(conn, "SELECT id, name FROM people ORDER BY id")
      assert result.rows == [[1, "Ada"], [2, "Grace"]]
      assert Result.column_names(result) == ["ID", "NAME"]

      assert Result.to_maps(result) == [
               %{"ID" => 1, "NAME" => "Ada"},
               %{"ID" => 2, "NAME" => "Grace"}
             ]

      assert result.num_rows == 2
      assert result.update_count == -1
      refute Result.update?(result)
    end

    test "several statements in one call answer one result each", %{conn: conn} do
      assert {:ok, results} =
               Frostlake.execute_all(conn, "SELECT 1; SELECT 2; SELECT 3", [],
                 multi_statement_count: 3
               )

      assert Enum.map(results, &Result.value/1) == [1, 2, 3]

      assert {:ok, first} =
               Frostlake.execute(conn, "SELECT 1; SELECT 2", [], multi_statement_count: 0)

      assert Result.value(first) == 1
    end

    test "an undeclared script is refused before any of it runs, from engine 0.1.0 on",
         %{conn: conn} do
      if engine_version(conn) >= {0, 1, 0} do
        {:ok, _} = Frostlake.execute(conn, "CREATE TABLE counted (id INTEGER)")

        assert {:error, %QueryError{} = error} =
                 Frostlake.execute_all(conn, "INSERT INTO counted VALUES (1); SELECT 2")

        assert error.message =~ "did not match the desired statement count 1"

        assert {:error, %QueryError{}} =
                 Frostlake.execute_all(conn, "INSERT INTO counted VALUES (1); SELECT 2", [],
                   multi_statement_count: 3
                 )

        assert {:ok, result} = Frostlake.execute(conn, "SELECT COUNT(*) FROM counted")
        assert Result.value(result) == 0
      end
    end

    test "the engine's own wording comes back for a statement it refuses", %{conn: conn} do
      assert {:error, %QueryError{} = error} =
               Frostlake.execute(conn, "SELECT * FROM missing_table")

      assert error.message =~ "missing_table" or error.message =~ "MISSING_TABLE"
      assert error.statement == "SELECT * FROM missing_table"
    end

    test "execute! raises what execute reports", %{conn: conn} do
      assert_raise QueryError, fn -> Frostlake.execute!(conn, "SELECT * FROM missing_table") end
      assert %Result{} = Frostlake.execute!(conn, "SELECT 1")
    end
  end

  describe "parameters" do
    test "are inlined positionally and by name", %{conn: conn} do
      assert {:ok, result} = Frostlake.execute(conn, "SELECT ? + ?", [2, 40])
      assert Result.value(result) == 42

      assert {:ok, result} = Frostlake.execute(conn, "SELECT :a + :b AS total", a: 2, b: 40)
      assert Result.value(result) == 42
      assert Result.column_names(result) == ["TOTAL"]
    end

    test "a string is escaped rather than ending the literal it sits in", %{conn: conn} do
      assert {:ok, result} = Frostlake.execute(conn, "SELECT ?", ["it's; DROP TABLE x; --"])
      assert Result.value(result) == "it's; DROP TABLE x; --"
    end

    test "a placeholder without an argument never reaches the engine", %{conn: conn} do
      assert {:error, %UsageError{} = error} = Frostlake.execute(conn, "SELECT ?, ?", [1])
      assert error.message =~ "placeholder"
    end
  end

  describe "types" do
    test "come back as the Elixir type the column names", %{conn: conn} do
      {:ok, _} =
        Frostlake.execute(conn, """
        CREATE TABLE kinds (
          n NUMBER(38,0), d NUMBER(10,2), f FLOAT, s VARCHAR, b BOOLEAN,
          dt DATE, tm TIME, ts TIMESTAMP_NTZ, bin BINARY
        )
        """)

      {:ok, _} =
        Frostlake.execute(
          conn,
          "INSERT INTO kinds VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
          [
            9_007_199_254_740_993,
            2.5,
            1.5,
            "text",
            true,
            ~D[2026-08-24],
            ~T[10:20:30],
            ~N[2026-08-24 10:20:30.500],
            {:binary, <<0x0A, 0x1B>>}
          ]
        )

      assert {:ok, result} = Frostlake.execute(conn, "SELECT * FROM kinds")
      assert [[n, d, f, s, b, dt, tm, ts, bin]] = result.rows

      assert n == 9_007_199_254_740_993
      assert d == 2.5
      assert f == 1.5
      assert s == "text"
      assert b == true
      assert dt == ~D[2026-08-24]
      assert tm == ~T[10:20:30]
      assert ts == ~N[2026-08-24 10:20:30.500]
      assert bin == <<0x0A, 0x1B>>
    end

    test "an integer past 64 bits survives the round trip", %{conn: conn} do
      big = 123_456_789_012_345_678_901_234_567_890

      assert {:ok, result} = Frostlake.execute(conn, "SELECT #{big}::NUMBER(38,0)")
      assert Result.value(result) == big
    end

    test "NULL is nil whatever the column", %{conn: conn} do
      assert {:ok, result} =
               Frostlake.execute(conn, "SELECT NULL::VARCHAR, NULL::NUMBER, NULL::DATE")

      assert result.rows == [[nil, nil, nil]]
    end

    test "a column says whether it admits NULL, and what it is", %{conn: conn} do
      {:ok, _} = Frostlake.execute(conn, "CREATE TABLE nn (id INTEGER NOT NULL, note VARCHAR)")
      assert {:ok, result} = Frostlake.execute(conn, "SELECT id, note FROM nn")
      assert [id, note] = result.columns
      assert id.name == "ID"
      assert String.starts_with?(id.data_type, "NUMBER")
      refute id.nullable
      assert note.nullable
    end
  end

  describe "sessions" do
    test "state carries from one statement to the next", %{conn: conn} do
      {:ok, _} = Frostlake.execute(conn, "CREATE OR REPLACE SCHEMA other_schema")
      {:ok, _} = Frostlake.execute(conn, "USE SCHEMA other_schema")

      assert {:ok, result} = Frostlake.execute(conn, "SELECT CURRENT_SCHEMA()")
      assert Result.value(result) |> String.downcase() == "other_schema"
    end

    test "concurrent callers land on the same session, one statement at a time", %{conn: conn} do
      {:ok, _} = Frostlake.execute(conn, "CREATE TABLE counter (n INTEGER)")

      tasks =
        for n <- 1..10 do
          Task.async(fn -> Frostlake.execute(conn, "INSERT INTO counter VALUES (#{n})") end)
        end

      assert Enum.all?(Task.await_many(tasks, 30_000), &match?({:ok, _}, &1))

      assert {:ok, result} = Frostlake.execute(conn, "SELECT COUNT(*) FROM counter")
      assert Result.value(result) == 10
    end
  end

  describe "transactions" do
    setup %{conn: conn} do
      {:ok, _} = Frostlake.execute(conn, "CREATE TABLE acc (n INTEGER)")
      :ok
    end

    test "commit keeps the rows", %{conn: conn} do
      assert {:ok, :done} =
               Frostlake.transaction(conn, fn c ->
                 {:ok, _} = Frostlake.execute(c, "INSERT INTO acc VALUES (1)")
                 :done
               end)

      assert {:ok, result} = Frostlake.execute(conn, "SELECT COUNT(*) FROM acc")
      assert Result.value(result) == 1
    end

    test "a raise rolls back and comes out as the original error", %{conn: conn} do
      assert_raise RuntimeError, "nope", fn ->
        Frostlake.transaction(conn, fn c ->
          {:ok, _} = Frostlake.execute(c, "INSERT INTO acc VALUES (1)")
          raise "nope"
        end)
      end

      refute Frostlake.in_transaction?(conn)
      assert {:ok, result} = Frostlake.execute(conn, "SELECT COUNT(*) FROM acc")
      assert Result.value(result) == 0
    end

    test "begin, commit and rollback are there for hand control", %{conn: conn} do
      assert :ok = Frostlake.begin(conn)
      assert Frostlake.in_transaction?(conn)
      {:ok, _} = Frostlake.execute(conn, "INSERT INTO acc VALUES (1)")
      assert :ok = Frostlake.rollback(conn)
      refute Frostlake.in_transaction?(conn)

      assert {:ok, result} = Frostlake.execute(conn, "SELECT COUNT(*) FROM acc")
      assert Result.value(result) == 0
    end
  end

  describe "the connection itself" do
    test "keeps answering after the socket has sat idle", %{conn: conn} do
      {:ok, _} = Frostlake.execute(conn, "SELECT 1")
      Process.sleep(1_500)
      assert {:ok, result} = Frostlake.execute(conn, "SELECT 2")
      assert Result.value(result) == 2
    end

    test "a closed connection refuses the next statement" do
      {:ok, conn} = Frostlake.connect(TestServer.dsn())
      assert :ok = Frostlake.close(conn)
      assert {:error, %UsageError{}} = Frostlake.execute(conn, "SELECT 1")
    end

    test "takes a per-statement deadline and an unbounded one", %{conn: conn} do
      # What a deadline does when it passes is covered against a server that can
      # be told not to answer; here it only has to reach the engine and come
      # back. Handing a real engine a statement it will never finish would leave
      # it running long after the test that abandoned it.
      assert {:ok, _} = Frostlake.execute(conn, "SELECT 1", [], timeout: 30_000)
      assert {:ok, _} = Frostlake.execute(conn, "SELECT 1", [], timeout: :infinity)
    end
  end

  defp spare_connection do
    {:ok, conn} = Frostlake.connect(TestServer.dsn())
    on_exit(fn -> Frostlake.close(conn) end)
    conn
  end

  # The engine's release as a comparable tuple: "0.1.1-SNAPSHOT" is {0, 1, 1}.
  defp engine_version(conn) do
    {:ok, result} = Frostlake.execute(conn, "SELECT CURRENT_VERSION()")

    ~r/\d+/
    |> Regex.scan(Result.value(result))
    |> Enum.take(3)
    |> Enum.map(fn [digits] -> String.to_integer(digits) end)
    |> List.to_tuple()
  end
end
