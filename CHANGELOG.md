# Changelog

## 0.2.0

- `close/1` hands the session back to the engine with `DELETE /api/sessions/{id}`, and so does a
  connection whose owner finishes. A closed connection's session no longer waits for the engine's
  30-minute idle sweep, and the engine rolls back a transaction left open in it. The release is
  best effort: it waits no longer than the connection's timeout or five seconds, whichever is
  shorter, and `close/1` answers `:ok` whatever the engine says. Engines before 0.1.0 have no such
  endpoint and are not asked.
- When engine 0.1.0 answers `newSession` for a session the connection already held, because its
  own was reaped, released or lost to a restart, the DSN's role, warehouse, database and schema go
  back on before the next statement. Before, the connection carried on at the server's default
  scope unless it had sat idle past `idleLimit`, and a `USE` of the caller's own kept even that
  off.
- Once an answer shows the engine marks `newSession` (0.1.0 and later), every request naming the
  session carries `requireSession: true`; an older engine is never sent it. A session the engine
  no longer holds is then refused before anything runs, and the connection puts the DSN's scope on
  a fresh session and sends the statement once more. When the lost session held an open
  transaction or a moved context (`USE`, `SET`/`UNSET`, `ALTER SESSION`, a temporary object, a
  `CREATE`/`DROP` of a database or schema), the statement is not re-run and the call answers the
  new `Frostlake.SessionLostError`; a `commit/2` of a transaction lost that way answers it too,
  rather than `:ok`. The connection stays usable either way, its next statement starting a fresh
  session on the DSN's scope.
- The `idleLimit` check now applies only to engines before 0.1.0, whose answers never say that a
  session was lost; a later engine refuses a lost session instead.
- Requires a Frostlake engine 0.2.0 or newer.

## 0.1.0

First release. A dependency-free Elixir driver for Frostlake over the engine's HTTP protocol,
verified against engines 0.0.7 and 0.1.0.

- `Frostlake.connect/2` opens a connection and applies the DSN's role, warehouse, database and
  schema before the first statement, so a name that does not exist is reported at connect. A
  plain name folds to upper case as it would in SQL, and a double-quoted one keeps its case.
  `Frostlake.Connection` is a `GenServer` with a `child_spec/1`, so a connection can live in a
  supervision tree instead.
- `execute/4` and `execute_all/4` take positional `?` parameters as a list and `:name` ones as a
  map or keyword list. Binding is client-side, skipping string literals, quoted identifiers,
  dollar-quoted bodies and comments, and refusing a count mismatch whenever arguments are
  supplied; with none at all the markers pass through to the server, where Snowflake Scripting
  binds them. `:multi_statement_count` declares how many statements a string holds, which engine
  0.1.0 requires of a string holding more than one.
- `Frostlake.Result` reports the grid positionally, with column metadata, a DML `update_count`
  and the raw counters behind it; `Result.to_maps/1` keys the rows by column name.
- Types map to Elixir natives: an exact `t:integer/0` for a `NUMBER` past 64 bits, `Date`,
  `Time`, `NaiveDateTime` and `DateTime` for the temporal types, raw bytes for `BINARY`, and
  `:nan` / `:infinity` / `:neg_infinity` for the floats Elixir cannot spell.
- `begin/2`, `commit/2`, `rollback/2` and a `transaction/3` helper that rolls back on a raise,
  a throw, an exit or an `{:error, reason}` body.
- Failures are typed: `Frostlake.QueryError`, `Frostlake.ConnectionError` and
  `Frostlake.UsageError`, each saying which side the failure came from.
- Statements on one connection are serialized by the connection process, so a connection maps
  to one engine session however many callers run statements on it at once.
- A statement that reached the wire is never re-sent: only a write that failed outright on a
  reused socket is retried, and a socket the server dropped while it was idle is replaced
  before anything is written to it.
- Tests: 126 and a doctest that need no engine, and — with `FROSTLAKE_CLASSPATH` set — 27
  integration tests against a real engine, passing on engines 0.0.7 and 0.1.0.
