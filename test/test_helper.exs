ExUnit.start(timeout: 120_000)

# The testkit suites are an ORDERED corpus. Account-level objects — a warehouse,
# an internal stage — outlive the per-test `CREATE OR REPLACE DATABASE test_db`
# that isolates the rest, so a case doing `CREATE WAREHOUSE wh` with no IF NOT
# EXISTS only passes when it runs before the suites that create the same
# warehouse. The reference runners walk the files in order; this one does too,
# rather than shuffling and failing on some seeds and not others.
ExUnit.configure(seed: 0)

# Owned by this process, which outlives every test, so a capability note
# recorded in one test is still there to print at the end of the run. The
# testkit runner is optional — the driver's own tests do not need it — so this
# asks whether it is here rather than assuming it.
if Code.ensure_loaded?(Frostlake.Testkit), do: Frostlake.Testkit.start_notes()

# One engine for the whole run: booting a JVM per test module would cost more
# than every statement in the suites put together.
case Frostlake.TestServer.start_shared() do
  :ok ->
    System.at_exit(fn _status -> Frostlake.TestServer.stop() end)

  {:skip, reason} ->
    IO.puts(:stderr, "\n[frostlake] tests that need an engine are excluded: #{reason}\n")
    ExUnit.configure(exclude: [:server])
end
