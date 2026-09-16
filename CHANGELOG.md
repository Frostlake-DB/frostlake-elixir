# Changelog

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
  integration tests plus the engine-owned JSON testkit suites: against engine 0.1.0, 6959 tests in
  all with no failures and 13 skipped.
