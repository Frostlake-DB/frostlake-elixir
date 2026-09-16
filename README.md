# frostlake-elixir

A dependency-free Elixir driver for [Frostlake](https://frostlake.dev), speaking the engine's
HTTP protocol against a running `DatabaseHttpServer`. Elixir 1.14+ on OTP 25+, `:gen_tcp` and
`:ssl` only — no JVM, no NIFs, and nothing in `mix.exs` to fetch.

## Engine version

Requires a Frostlake engine **0.0.7 or newer**, and is verified against 0.0.7 and 0.1.0. Ask a
running server which one it is with `SELECT CURRENT_VERSION()` — every release answers it, so the
check works against any engine.

The driver versions independently of the engine: it speaks the HTTP protocol, not the jar, so
this is a floor rather than a lockstep pin.

## Installation

Not on Hex yet. Point at the repository, or at a checkout:

```elixir
def deps do
  [{:frostlake, github: "Frostlake-DB/frostlake-elixir"}]
end
```

## Usage

```elixir
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
```

`connect/2` contacts the server before it returns: it calls the health endpoint and applies the
scope the DSN names, so a database that does not exist is reported there rather than surfacing
later on whichever query happened to run first.

Every call answers `{:ok, value}` or `{:error, exception}`; `execute!/4` and `execute_all!/4`
raise instead.

### In a supervision tree

```elixir
children = [
  {Frostlake.Connection, dsn: "frostlake://localhost:18082/MY_DB", name: MyApp.DB}
]
```

Statements then run as `Frostlake.execute(MyApp.DB, sql)`. A supervised connection is not handed
a statement while it starts up, so it does not contact the server in `init/1`; the DSN's scope
is applied ahead of the first statement instead.

### DSN

```
frostlake://host[:port][/DATABASE][?param=value&…]
```

`http://` and `https://` are accepted too and mean the same thing. Omitting the port means the
engine's own default, `18082`; for `http`/`https` it means their standard ports.

| Parameter | Meaning | Default |
| --- | --- | --- |
| `schema` | schema to `USE` on the session | — |
| `role` | role to `USE` on the session | — |
| `warehouse` | warehouse to `USE` on the session | — |
| `timeout` | how long one statement may take; `0` removes the bound | `5m` |
| `connectTimeout` | how long to wait for the socket | `10s` |
| `idleLimit` | how long a connection may idle before its scope is re-applied; `0` switches the check off | `30m` |
| `tls` | `true` to speak HTTPS — an `https://` DSN does the same | `false` |

A database, schema, role or warehouse name means what it would mean written in SQL. A plain name
folds to upper case, so `my_db` selects `MY_DB`; a name wrapped in double quotes — `%22my_db%22`
in the URL — keeps its exact case; anything else, such as `my db`, is quoted exactly as given.

Durations are written as a bare number of seconds or with a `ms`/`s`/`m`/`h` suffix. Each
parameter may also be spelled the way Elixir reads more naturally — `connect_timeout`,
`idle_limit` — and either spelling means the same thing. An unknown parameter is an error rather
than a silent no-op, and so is a username or password: the engine's HTTP API has no
authentication to hand them to, and quietly dropping a password is worse than saying so.

Every parameter can also be passed to `connect/2` directly, where an explicit option outranks
the DSN and durations may be given as milliseconds:

```elixir
Frostlake.connect("frostlake://localhost", database: "MY_DB", timeout: 30_000)
```

`:database`, `:schema`, `:role`, `:warehouse`, `:timeout`, `:connect_timeout`, `:idle_limit`,
`:tls`, `:verify_certificate`, `:cacerts`, `:cacertfile` and `:name` are the options.

### Results

`execute/4` answers a `Frostlake.Result`:

| Field or function | What it holds |
| --- | --- |
| `columns` | a `Frostlake.Column` per column: name, declared type, nullability, precision, scale |
| `rows` | every row as a list of cells, positionally aligned with `columns` — the lossless view |
| `Result.to_maps/1` | each row keyed by column name |
| `Result.value/1` | the first cell of the first row, for a single-value query |
| `num_rows` | rows returned, or rows affected for DML |
| `update_count` | rows affected by DML, or `-1` when the statement returned data |
| `counters` | the raw `number of rows …` counters behind `update_count` |

A map cannot represent two columns called the same thing — a self-join reports `ID` twice and
the later one wins — which is why `rows` stays positional and `to_maps/1` is a function you
call rather than a field.

A statement string holding several `;`-separated statements answers with one result each:
`execute_all/4` returns them all, and `execute/4` hands back the first. Such a string says how
many statements it holds, the way Snowflake's own drivers do, and engine 0.1.0 refuses any other
number before running any of it:

```elixir
Frostlake.execute_all(conn, "INSERT INTO t VALUES (1); SELECT * FROM t", [], multi_statement_count: 2)
```

`0` accepts any number. Without the option the session's `MULTI_STATEMENT_COUNT` decides: it
starts at 1, and `ALTER SESSION SET MULTI_STATEMENT_COUNT = 0` lifts it for the rest of the
session. Engines before 0.1.0 run any number and ignore the option.

### Bind values

Parameters are inlined client-side — the protocol has no server-side binding — with the same
rules as Frostlake's JDBC driver. A `?` inside a string literal, quoted identifier, `$$…$$`
body or comment is never a placeholder, and the argument count has to match exactly whenever
arguments are supplied. With no arguments at all the markers pass through to the server: a `?`
is then a Snowflake Scripting cursor placeholder bound by `OPEN c USING (...)`, and `:name` a
Scripting variable.

| Elixir value | SQL literal |
| --- | --- |
| `nil` | `NULL` |
| `true` / `false` | `TRUE` / `FALSE` |
| integer | the digits, exactly, at any width |
| float | the shortest round-tripping form |
| `:nan`, `:infinity`, `:neg_infinity` | `'NaN'::FLOAT` and friends |
| binary | `'…'`, backslashes and quotes escaped |
| `{:binary, bytes}` | `X'hex'` |
| `%Date{}` | `'…'::DATE` |
| `%Time{}` | `'…'::TIME` |
| `%NaiveDateTime{}` | `'…'::TIMESTAMP_NTZ` |
| `%DateTime{}` | `'…'::TIMESTAMP_TZ`, carrying its offset |
| `%Decimal{}` | the digits, when the optional `Decimal` package is loaded |
| list | `[…]`, elements formatted recursively |
| map | `{'key': …}`, values formatted recursively |

A string and a blob are the same type in Elixir, so `{:binary, bytes}` is the deliberate marker
for `BINARY`. A plain binary is text, and one that is not valid UTF-8 is refused rather than
guessed at — it is far more often a blob that forgot its tag than a broken string.

Positional parameters come as a list; named ones as a map or keyword list, matched
case-insensitively and in any order:

```elixir
Frostlake.execute(conn, "SELECT :a + :b AS total", a: 2, b: 40)
```

A `::` cast, a `:=` assignment and a `:1` positional reference are never parameters — and
neither is Snowflake's VARIANT path access: a colon glued to the end of an expression
(`v:field`, `PARSE_JSON('…'):k`, `"V":k`) reads a field, so a bind marker has to follow an
operator, comma or keyword boundary. With **no arguments at all**, colon references pass through
to the server untouched, because that is what Snowflake Scripting variables look like
(`EXECUTE IMMEDIATE :v`, `IFF(:flag, …)`).

Which style a statement uses is what decides how a list is read, rather than what the list looks
like: `[{:binary, <<1>>}]` is one positional argument and also a perfectly good keyword list, and
only the statement can settle it.

### Types coming back

| SQL type | Elixir type |
| --- | --- |
| integral `NUMBER`, `INTEGER` and friends | `integer`, exact at any width |
| fractional `NUMBER`, `FLOAT`, `DOUBLE`, `REAL` | `float` |
| `VARCHAR` and the text types | `String.t` |
| `BOOLEAN` | `boolean` |
| `BINARY` | a binary of the decoded bytes |
| `DATE` | `Date` |
| `TIME` | `Time` |
| `TIMESTAMP`, `TIMESTAMP_NTZ`, `DATETIME` | `NaiveDateTime` |
| `TIMESTAMP_LTZ`, `TIMESTAMP_TZ` | `DateTime` — the instant, in UTC |
| `VARIANT`, `OBJECT`, `ARRAY` | `String.t`, the value's JSON text |

A semi-structured cell is left as JSON text for the caller to decode. From engine 0.1.0 on that
text is what Snowflake's own drivers hand back, so a `VARIANT` holding a string arrives with its
quotes — `"a"` rather than `a`.

A `NUMBER(38,0)` holds integers no 64-bit word can name. The driver's JSON layer decodes an
integer literal to an Elixir integer rather than a float, so those arrive exact.

A fractional `NUMBER` becomes a float, which is not exact past 15 significant digits: Elixir has
no decimal of its own, and a driver with no dependencies cannot borrow one. Read such a column
as text — `TO_VARCHAR(amount)` — when the last digit matters.

A `DATE` and a `TIMESTAMP_NTZ` are wall clocks with no zone of their own, and `Date` and
`NaiveDateTime` have none either, so their fields read back exactly as stored rather than being
shifted by whatever zone the host is in. A `TIMESTAMP_TZ` names an instant, and arrives as a
`DateTime` in UTC — the same choice `DateTime.from_iso8601/1` makes for a string carrying an
offset.

A `FLOAT` that is not a number arrives as `:nan`, `:infinity` or `:neg_infinity`, because an
Elixir float has no way to spell those. They go back the same way.

### Transactions

```elixir
Frostlake.transaction(conn, fn c ->
  Frostlake.execute!(c, "INSERT INTO acc VALUES (1)")
end)
```

The helper commits when the body returns and answers `{:ok, value}`; it rolls back and hands
back the error when the body answers `{:error, reason}`; and it rolls back and re-raises when the
body raises, throws or exits. `begin/2`, `commit/2` and `rollback/2` are there for hand-rolled
control. The engine offers read committed.

A transaction lives on the session, not on the closure, so anything else run on the same
connection meanwhile joins it. Give a transaction its own connection if that is not what you
want.

### Errors

Three exceptions, by which side the failure came from — the distinction a caller actually
branches on:

- **`Frostlake.QueryError`** — the engine refused the statement. `message` is the engine's own
  wording, unmodified.
- **`Frostlake.ConnectionError`** — the request never became an answer: the host refused, the
  socket died, the deadline passed, or a proxy replied with something that is not a Frostlake
  response. A statement that failed this way has an *unknown* fate, so it must not be blindly
  retried — re-running an `INSERT` would duplicate it.
- **`Frostlake.UsageError`** — the driver never sent it: a malformed DSN, a closed connection, a
  bind value with no SQL equivalent, a placeholder left without an argument.

**`QueryError.statement` holds the rendered SQL.** Because binding is client-side, that means
every parameter inlined — a bound password or card number appears in it verbatim.
`Exception.message/1` carries none of it, so log that freely and treat `:statement` as sensitive.

### Sessions and concurrency

One HTTP session per connection process. Statements are serialized in call order, so several
processes may use one connection safely and stay on one session — which is what keeps `USE`,
session variables and an open transaction carrying from one statement to the next.

```elixir
tasks = [
  Task.async(fn -> Frostlake.execute(conn, "INSERT INTO t VALUES (1)") end),
  Task.async(fn -> Frostlake.execute(conn, "INSERT INTO t VALUES (2)") end)
]

Task.await_many(tasks)  # serialized, one session
```

The socket is kept alive between statements and dropped by `close/1`. A statement that reached
the wire is never sent a second time: the only recovery the driver performs is for a **reused**
socket whose write failed outright, where nothing was transmitted at all. A socket the server
closed while it sat idle — which the engine's own HTTP server does — is spotted before a request
is written to it, so the caller never sees it happen.

For a pool, put several connections under your own supervisor and pick between them; the driver
ships no pool of its own, because a connection is one session and pooling sessions is a policy
question rather than a transport one.

## Known limitations

- **Server sessions are not released on close.** Engine 0.1.0 can end a session
  (`DELETE /api/sessions/{id}`), but the driver does not call it yet, and earlier engines have no
  such endpoint. A closed connection's session therefore lingers until the engine's own 30-minute
  idle sweep reclaims it, and connection churn accrues server-side sessions.
- **A session idle past that sweep resumes at the server's default scope**, because the engine
  re-creates an expired session under the very same id. Engine 0.1.0 marks such an answer
  `newSession`, but the driver does not read the mark yet, and before 0.1.0 nothing in the answer
  tells. The driver covers this by re-applying the DSN's scope to a connection that has been idle
  longer than `idleLimit`, but anything else the session held (a session variable, an
  `ALTER SESSION` setting) is gone. It stops doing so once the caller has issued their own `USE`,
  since the DSN no longer describes where they are.
- **Temporal values keep microseconds.** Engine 0.1.0 sends a timestamp or a time with all nine
  fractional digits, but Elixir's `Time`, `NaiveDateTime` and `DateTime` hold six, so the last
  three are dropped. Engines before 0.1.0 send milliseconds, and a `TIME` in whole seconds.
  `TO_VARCHAR(ts, 'YYYY-MM-DD HH24:MI:SS.FF9')` is the way to read every digit.
- **Failures carry no error code.** The protocol reports a message only — no code, no SQLSTATE —
  so `QueryError` has none to offer.
- **Before engine 0.1.0 a blank statement is refused by the endpoint**, with HTTP 400 and
  `SQL is required`, before the engine sees it. From 0.1.0 on it reaches the engine and answers
  `Empty SQL statement.`, as a lone `;` always did.
- **Fractional `NUMBER` columns come back as floats**, as described under
  [Types coming back](#types-coming-back).

## Tests

The unit tests need nothing installed — no engine, no JVM. They cover the JSON codec, the DSN
parser, the SQL scanner, parameter binding, value conversion, and the transport itself against a
scriptable fake server that produces the answers a healthy engine never gives — a proxy's error
page, a socket dropped between statements, a reply that never comes:

```bash
mix test
```

**126 tests and a doctest, no failures**, and the tests that need an engine are excluded rather
than passing on a stub.

The integration tests additionally boot a real `DatabaseHttpServer` from an engine classpath —
the engine jar and its dependency jars, joined with `:` (`;` on Windows):

```bash
JAVA_HOME=/path/to/jdk17 FROSTLAKE_CLASSPATH="<engine jar>:<dependency jars>" mix test
```

That run also includes the **engine-owned, language-neutral JSON suites**
(`engine/src/test/resources/testkit/suites/*.json`, spec in `SCHEMA.md` beside them), one ExUnit
test per case, every statement travelling `connect` → HTTP → `DatabaseHttpServer`. The engine
owns the definitions and this repo only holds the runner, so suites added on the engine side are
picked up with no driver change. Point `FROSTLAKE_TESTKIT_SUITES` at them, or check `frostlake`
out beside this repo.

Against engine 0.1.0 and the suites tagged with it the whole run passes with no failures:
**6959 tests, 13 skipped** at the time of writing, the skips being the suites' own `skip`
declarations. That total tracks however many suites the engine currently ships — the corpus grows
on the engine side — so treat it as a reading rather than a fixed number; what stays true is that
the run is clean.

The run is deterministic on purpose (`seed: 0`). The suites are an ordered corpus: account-level
objects — a warehouse, an internal stage — outlive the per-test `CREATE OR REPLACE DATABASE
test_db` that isolates everything else, so a case creating `wh` with no `IF NOT EXISTS` only
passes when it runs before the suites that create the same warehouse. The reference runners walk
the files in order, and so does this one.

One capability note prints at the end, for the error codes described under
[Known limitations](#known-limitations). It is not a failure: it records a check this transport
cannot express, so the day the protocol carries an error code the check lights up without a test
changing.

The engine the tests boot is pinned to a directory of that run's own (`_build/engine-<port>`,
emptied before boot), because a default-configured engine persists its catalog and its internal
stages under the user's home directory — consecutive runs would otherwise inherit each other's
warehouses and tables, and would walk over whatever engine the developer runs for themselves.

## License

Apache-2.0 — see [LICENSE](LICENSE).
