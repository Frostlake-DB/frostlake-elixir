defmodule Frostlake.SuitesTest do
  @moduledoc """
  The engine-owned JSON test suites, one ExUnit test per case, driven through
  this driver.

      FL_CORPUS=<frostlake>/engine/src/test/resources/testkit \\
        JAVA_HOME=... FROSTLAKE_CLASSPATH=... mix test test/frostlake/suites_test.exs

  Without FL_CORPUS the corpus is one skipped test, and a FL_CORPUS with no
  suites under it fails. Without an engine the cases are excluded.
  """

  use ExUnit.Case, async: false

  alias Frostlake.Testkit
  # Only the generated cases use it, and without FL_CORPUS there are none.
  alias Frostlake.TestServer, warn: false

  @moduletag timeout: 120_000

  setup_all do
    on_exit(fn ->
      case Testkit.notes() do
        [] -> :ok
        notes -> IO.puts("\n" <> Enum.join(notes, "\n"))
      end
    end)

    :ok
  end

  # Read when this module compiles, which `mix test` does on every run. Only the
  # generated cases need the engine; the placeholders below skip or fail whether
  # or not one started.
  corpus = Testkit.corpus()
  cases = if corpus, do: Testkit.cases(), else: []

  cond do
    corpus == nil ->
      # Named after its own reason, because ExUnit reports a skip without one:
      # this way `mix test --trace` shows it.
      @skip_reason "set FL_CORPUS to frostlake's engine/src/test/resources/testkit " <>
                     "to replay the testkit corpus"
      @tag skip: @skip_reason
      test @skip_reason do
        :ok
      end

    cases == [] ->
      @missing "FL_CORPUS=#{corpus} holds no testkit suites: no *.json in " <>
                 Testkit.suites_directory()
      test "the testkit suites are where they should be" do
        flunk(@missing)
      end

    true ->
      @moduletag :server
  end

  # Names are made unique here rather than trusted to be: two suites are free to
  # call a case the same thing, and ExUnit refuses a module with two tests of one
  # name.
  cases
  |> Enum.map(fn {suite, test_case} ->
    {"#{suite}/#{Map.get(test_case, "name", "unnamed")}", test_case}
  end)
  |> Enum.map_reduce(%{}, fn {name, test_case}, seen ->
    count = Map.get(seen, name, 0)
    unique = if count == 0, do: name, else: "#{name} ##{count + 1}"
    {{unique, test_case}, Map.put(seen, name, count + 1)}
  end)
  |> elem(0)
  |> Enum.each(fn {name, test_case} ->
    @testkit_case test_case

    case Testkit.skip_reason(test_case) do
      nil -> :ok
      reason -> @tag skip: reason
    end

    test name do
      case Testkit.run_case(@testkit_case, TestServer.dsn()) do
        :ok -> :ok
        {:failed, problem} -> flunk(problem)
      end
    end
  end)
end
