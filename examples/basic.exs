# A tour of the driver against a running DatabaseHttpServer.
#
#     mix run examples/basic.exs [dsn]
#
# The DSN defaults to frostlake://localhost:18082, which is where an engine
# started with `java -cp <classpath> dev.frostlake.http.DatabaseHttpServer`
# listens.

dsn = List.first(System.argv()) || "frostlake://localhost:18082"

{:ok, conn} = Frostlake.connect(dsn)

IO.puts(
  "engine #{Frostlake.execute!(conn, "SELECT CURRENT_VERSION()") |> Frostlake.Result.value()}"
)

IO.puts("session #{Frostlake.session_id(conn)}")

Frostlake.execute!(conn, "CREATE OR REPLACE DATABASE frostlake_example")
Frostlake.execute!(conn, "USE DATABASE frostlake_example")
Frostlake.execute!(conn, "CREATE OR REPLACE SCHEMA demo")
Frostlake.execute!(conn, "USE SCHEMA demo")

Frostlake.execute!(conn, """
CREATE TABLE people (id INTEGER, name VARCHAR, born DATE, note VARIANT)
""")

inserted =
  Frostlake.execute!(
    conn,
    "INSERT INTO people SELECT ?, ?, ?, PARSE_JSON(?)",
    [1, "Ada Lovelace", ~D[1815-12-10], ~s({"field":"mathematics"})]
  )

IO.puts("inserted #{inserted.update_count} row(s) #{inspect(inserted.counters)}")

# A transaction: it commits when the body returns, and rolls back if it raises.
{:ok, _} =
  Frostlake.transaction(conn, fn c ->
    Frostlake.execute!(c, "INSERT INTO people VALUES (?, ?, ?, NULL)", [
      2,
      "Grace Hopper",
      ~D[1906-12-09]
    ])
  end)

result = Frostlake.execute!(conn, "SELECT id, name, born, note FROM people ORDER BY id")

IO.puts("\n" <> Enum.join(Frostlake.Result.column_names(result), " | "))

for row <- result.rows do
  IO.puts(Enum.map_join(row, " | ", &inspect/1))
end

# Named parameters, matched case-insensitively and in any order.
total = Frostlake.execute!(conn, "SELECT :a + :b AS total", b: 40, a: 2)
IO.puts("\n:a + :b = #{Frostlake.Result.value(total)}")

# Failures are typed, and say which side they came from.
case Frostlake.execute(conn, "SELECT * FROM no_such_table") do
  {:error, %Frostlake.QueryError{} = error} ->
    IO.puts("\nthe engine refused it: #{error.message}")

  other ->
    IO.puts("\nunexpected: #{inspect(other)}")
end

Frostlake.execute!(conn, "DROP DATABASE frostlake_example")
:ok = Frostlake.close(conn)
