defmodule Frostlake.Testkit do
  @moduledoc """
  Runs the engine-owned, language-neutral JSON test suites through this driver.

  The definitions live in the frostlake repo
  (`engine/src/test/resources/testkit/suites/*.json`, spec in `SCHEMA.md` next to
  them) and are read from the testkit directory `FL_CORPUS` names; every
  statement travels `connect` → HTTP → `DatabaseHttpServer`. The engine owns the
  definitions and this module is only the Elixir driver's runner, so suites added
  on the engine side are picked up here with no driver change at all.

  Semantics, mirroring SCHEMA.md and the Dart, Go, Ruby and .NET runners:

    * the backend name for a suite's `skip` clause is `elixir`; `http` entries are
      honoured too, because this driver rides the HTTP transport and the same
      engine
    * per-test isolation: `ALTER SESSION SET MULTI_STATEMENT_COUNT = 0` →
      `CREATE OR REPLACE DATABASE test_db` → `USE` →
      `CREATE OR REPLACE SCHEMA test_schema` → `USE`, then the steps on ONE
      connection, which is what keeps USE, variables and transactions on a single
      session. The count comes first because several cases send a script, and a
      session holds one statement per request unless it is told otherwise
    * a VARIANT, OBJECT or ARRAY cell arrives as its JSON text, a string's own
      quotes included, while the suites record the value: such a cell is decoded
      one level before comparing, as the reference HTTP backend does
    * capabilities SESSION, COLUMN_NAMES and UPDATE_COUNT. No ERROR_CODE — the
      HTTP protocol carries a message only, so expected-error code and sqlState
      checks are recorded as missing-API notes rather than failing
  """

  alias Frostlake.{Column, JSON, Result, Values}

  @backend "elixir"

  @reset [
    "ALTER SESSION SET MULTI_STATEMENT_COUNT = 0",
    "CREATE OR REPLACE DATABASE test_db",
    "USE DATABASE test_db",
    "CREATE OR REPLACE SCHEMA test_schema",
    "USE SCHEMA test_schema"
  ]

  @doc """
  Every case in every suite, as `{suite, case}` pairs in file order.

  Reads the files at compile time of the test module that calls it, which is
  what lets each case be its own ExUnit test.
  """
  @spec cases() :: [{String.t(), map()}]
  def cases do
    for path <- suite_files(),
        suite = JSON.decode!(File.read!(path)),
        is_map(suite),
        name = Path.basename(path, ".json"),
        test_case <- Map.get(suite, "tests", []),
        is_map(test_case) do
      {name, test_case}
    end
  end

  @doc """
  The testkit directory `FL_CORPUS` names — the frostlake repo's
  `engine/src/test/resources/testkit` — or `nil` when it is unset or empty. A
  relative path is taken from the working directory.
  """
  @spec corpus() :: String.t() | nil
  def corpus do
    case System.get_env("FL_CORPUS") do
      corpus when is_binary(corpus) and corpus != "" -> corpus
      _ -> nil
    end
  end

  @doc "The suites directory under `FL_CORPUS`, or `nil` when it is not set."
  @spec suites_directory() :: String.t() | nil
  def suites_directory do
    case corpus() do
      nil -> nil
      corpus -> Path.join(corpus, "suites")
    end
  end

  defp suite_files do
    case suites_directory() do
      nil -> []
      directory -> directory |> Path.join("*.json") |> Path.wildcard() |> Enum.sort()
    end
  end

  @doc "Why a suite says this backend cannot run a case, or `nil`."
  @spec skip_reason(map()) :: String.t() | nil
  def skip_reason(test_case) do
    with %{"backends" => backends} when is_list(backends) <- Map.get(test_case, "skip"),
         true <- Enum.any?(backends, &(String.downcase(to_string(&1)) in [@backend, "http"])) do
      "declared in the suite: #{Map.get(test_case, "skip")["reason"] || "no reason given"}"
    else
      _ -> nil
    end
  end

  @doc """
  Runs one case and returns `:ok`, or `{:failed, message}` naming the step.

  Notes about checks this transport cannot express are collected in the calling
  process and read back with `notes/0`.
  """
  @spec run_case(map(), String.t()) :: :ok | {:failed, String.t()}
  def run_case(test_case, dsn) do
    {:ok, conn} = Frostlake.connect(dsn)

    try do
      with :ok <- reset_context(conn) do
        test_case
        |> Map.get("steps", [])
        |> Enum.with_index(1)
        |> Enum.reduce_while(:ok, fn {step, index}, _acc ->
          sql = to_string(Map.get(step, "sql", ""))
          outcome = run_step(conn, sql)

          case check(Map.get(step, "expect"), outcome, sql) do
            :ok -> {:cont, :ok}
            {:failed, problem} -> {:halt, {:failed, "step #{index}: #{problem}\n  [sql: #{sql}]"}}
          end
        end)
      end
    after
      Frostlake.close(conn)
    end
  end

  defp reset_context(conn) do
    Enum.reduce_while(@reset, :ok, fn sql, _acc ->
      case run_step(conn, sql) do
        %{error: nil} -> {:cont, :ok}
        %{error: message} -> {:halt, {:failed, ~s(reset context failed on "#{sql}": #{message})}}
      end
    end)
  end

  defp run_step(conn, sql) do
    case Frostlake.execute(conn, sql) do
      {:ok, %Result{} = result} ->
        %{
          columns: Result.column_names(result),
          rows: Enum.map(result.rows, &row_text(&1, result.columns)),
          update_count: result.update_count,
          error: nil
        }

      {:error, %Frostlake.QueryError{} = error} ->
        %{columns: [], rows: [], update_count: -1, error: Exception.message(error)}

      {:error, error} ->
        # A ConnectionError (the transport) or a UsageError (the driver refusing
        # to send) satisfies no expectation — a dead engine must not pass an
        # `error` step — so it surfaces as the case's own failure: SCHEMA.md's
        # ERROR rather than FAIL.
        raise error
    end
  end

  defp row_text(row, columns) do
    row
    |> Enum.zip(columns)
    |> Enum.map(fn {cell, column} -> column |> semi_structured_value(cell_text(cell, column)) end)
  end

  # Only a semi-structured column, and only one level: a cell that is a JSON
  # string becomes that string's content, which for a whole object or array is
  # the object's own text. Anything else is left exactly as it came.
  defp semi_structured_value(%Column{data_type: type}, text)
       when is_binary(text) and is_binary(type) do
    if String.upcase(type) in ["VARIANT", "OBJECT", "ARRAY"] do
      case JSON.decode(text) do
        {:ok, value} when is_binary(value) -> value
        _ -> text
      end
    else
      text
    end
  end

  defp semi_structured_value(_column, text), do: text

  ## Expectations

  defp check(expectation, outcome, _sql) when not is_map(expectation) do
    if outcome.error, do: {:failed, "unexpected error: #{outcome.error}"}, else: :ok
  end

  defp check(expectation, outcome, sql) do
    if Map.has_key?(expectation, "error") do
      check_error(expectation["error"], outcome, sql)
    else
      with :ok <- check_success(outcome),
           :ok <- check_value(expectation, outcome),
           :ok <- check_rows(expectation, outcome),
           :ok <- check_row_count(expectation, outcome),
           :ok <- check_columns(expectation, outcome) do
        check_update_count(expectation, outcome)
      end
    end
  end

  defp check_error(_expected, %{error: nil}, _sql) do
    {:failed, "expected an error, the statement succeeded"}
  end

  defp check_error(expected, outcome, sql) when is_map(expected) do
    if expected["code"] || expected["sqlState"] do
      note(
        "missing-API [#{@backend}] ERROR_CODE: failures carry a message only, " <>
          "so an error code or SQLSTATE cannot be checked"
      )
    end

    case expected["messageContains"] do
      nil ->
        :ok

      wanted ->
        if String.contains?(String.downcase(outcome.error), String.downcase(to_string(wanted))) do
          :ok
        else
          blank_statement_note(sql, outcome, wanted)
        end
    end
  end

  defp check_error(_expected, _outcome, _sql), do: :ok

  # A blank statement is refused by the HTTP endpoint itself — 400, "SQL is
  # required" — so the engine never runs it and never produces its own wording.
  # No driver over this transport can, which makes it a capability gap rather
  # than a mismatch. The statement did still fail.
  defp blank_statement_note(sql, outcome, wanted) do
    if String.trim(sql) == "" do
      note(
        "missing-API [#{@backend}] EMPTY_STATEMENT: the HTTP API refuses a blank " <>
          "statement itself (HTTP 400 \"SQL is required\"), so the engine's own " <>
          "\"Empty SQL statement.\" error cannot be observed over this transport"
      )

      :ok
    else
      {:failed, "the error [#{outcome.error}] does not contain [#{wanted}]"}
    end
  end

  defp check_success(%{error: nil}), do: :ok
  defp check_success(%{error: message}), do: {:failed, "unexpected error: #{message}"}

  defp check_value(expectation, outcome) do
    if Map.has_key?(expectation, "value") do
      actual = outcome.rows |> List.first([]) |> List.first()
      wanted = expectation["value"]

      if normalize(scalar_text(wanted)) == normalize(actual) do
        :ok
      else
        {:failed, "value [#{actual || "NULL"}] != expected [#{scalar_text(wanted) || "NULL"}]"}
      end
    else
      :ok
    end
  end

  defp check_rows(expectation, outcome) do
    case expectation["rows"] do
      wanted when is_list(wanted) ->
        want =
          for row <- wanted, is_list(row) do
            Enum.map_join(row, " | ", &normalize(scalar_text(&1)))
          end

        got = Enum.map(outcome.rows, fn row -> Enum.map_join(row, " | ", &normalize/1) end)

        {want, got} =
          if expectation["ordered"] == true do
            {want, got}
          else
            {Enum.sort(want), Enum.sort(got)}
          end

        if want == got do
          :ok
        else
          {:failed, "rows differ:\n    expected #{inspect(want)}\n    got      #{inspect(got)}"}
        end

      _ ->
        :ok
    end
  end

  defp check_row_count(expectation, outcome) do
    case as_integer(expectation["rowCount"]) do
      nil -> :ok
      wanted when wanted == length(outcome.rows) -> :ok
      wanted -> {:failed, "rowCount #{length(outcome.rows)} != expected #{wanted}"}
    end
  end

  defp check_columns(expectation, outcome) do
    case expectation["columns"] do
      wanted when is_list(wanted) ->
        want = Enum.map(wanted, &String.upcase(to_string(&1)))
        got = Enum.map(outcome.columns, &String.upcase/1)

        if want == got,
          do: :ok,
          else: {:failed, "columns #{inspect(got)} != expected #{inspect(want)}"}

      _ ->
        :ok
    end
  end

  defp check_update_count(expectation, outcome) do
    case as_integer(expectation["updateCount"]) do
      nil -> :ok
      wanted when wanted == outcome.update_count -> :ok
      wanted -> {:failed, "updateCount #{outcome.update_count} != expected #{wanted}"}
    end
  end

  ## Rendering and normalization

  @doc """
  Renders a converted cell the way the other runners' transports render theirs.
  """
  @spec cell_text(term(), Column.t()) :: String.t() | nil
  def cell_text(nil, _column), do: nil
  def cell_text(true, _column), do: "true"
  def cell_text(false, _column), do: "false"
  def cell_text(value, _column) when is_integer(value), do: Integer.to_string(value)
  def cell_text(value, _column) when is_float(value), do: Float.to_string(value)
  def cell_text(%Date{} = value, _column), do: Date.to_string(value)
  def cell_text(%Time{} = value, _column), do: Time.to_string(value)
  def cell_text(%NaiveDateTime{} = value, _column), do: NaiveDateTime.to_string(value)

  def cell_text(%DateTime{} = value, _column) do
    value |> DateTime.to_naive() |> NaiveDateTime.to_string()
  end

  def cell_text(value, _column) when value in [:nan, :infinity, :neg_infinity] do
    case value do
      :nan -> "NaN"
      :infinity -> "Infinity"
      :neg_infinity -> "-Infinity"
    end
  end

  def cell_text(value, column) when is_binary(value) do
    if Values.binary_type?(column.data_type), do: Base.encode16(value, case: :upper), else: value
  end

  def cell_text(value, _column), do: to_string(value)

  defp scalar_text(nil), do: nil
  defp scalar_text(true), do: "true"
  defp scalar_text(false), do: "false"
  defp scalar_text(value) when is_binary(value), do: value
  defp scalar_text(value) when is_integer(value), do: Integer.to_string(value)
  defp scalar_text(value) when is_float(value), do: Float.to_string(value)
  defp scalar_text(value), do: to_string(value)

  @doc """
  SCHEMA.md value normalization, applied to both sides before comparing:
  `null`/empty becomes NULL, booleans compare case-insensitively, anything
  numeric compares as a number rounded to 10 significant digits, and everything
  else is an exact trimmed string.
  """
  @spec normalize(String.t() | nil) :: String.t()
  def normalize(nil), do: "NULL"

  def normalize(value) do
    text = String.trim(value)
    lower = String.downcase(text)

    cond do
      text == "" -> "NULL"
      lower == "null" -> "NULL"
      lower == "true" -> "TRUE"
      lower == "false" -> "FALSE"
      true -> numeric_or_text(text)
    end
  end

  defp numeric_or_text(text) do
    case Float.parse(text) do
      {number, ""} -> if number == 0, do: "0", else: significant10(number)
      _ -> text
    end
  end

  # The equivalent of %.10g: ten significant digits with trailing zeros dropped,
  # so 2 and 2.000000 compare equal and so do 3.5 and 3.500000.
  defp significant10(number) do
    text = :erlang.float_to_binary(number, [{:scientific, 9}])
    [mantissa, exponent] = String.split(text, "e")

    case Integer.parse(exponent) do
      {power, ""} when power >= -4 and power < 10 ->
        number
        |> :erlang.float_to_binary([{:decimals, max(9 - power, 0)}])
        |> drop_trailing_zeros()

      _ ->
        drop_trailing_zeros(mantissa) <> "e" <> exponent
    end
  end

  defp drop_trailing_zeros(text) do
    if String.contains?(text, ".") do
      text |> String.replace(~r/0+$/, "") |> String.replace(~r/\.$/, "")
    else
      text
    end
  end

  defp as_integer(value) when is_integer(value), do: value

  defp as_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp as_integer(value) when is_float(value) do
    if trunc(value) == value, do: trunc(value)
  end

  defp as_integer(_value), do: nil

  ## Capability notes

  @doc """
  Opens the table the notes are collected in.

  Called from `test_helper.exs`, so the table belongs to a process that outlives
  every test: a table opened by a test process dies with that test, taking the
  notes with it.
  """
  @spec start_notes() :: :ok
  def start_notes do
    :ets.new(__MODULE__, [:set, :public, :named_table])
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Records a note about a check this transport cannot express."
  @spec note(String.t()) :: :ok
  def note(text) do
    if :ets.whereis(__MODULE__) != :undefined, do: :ets.insert(__MODULE__, {text})
    :ok
  end

  @doc "Every note recorded so far, sorted."
  @spec notes() :: [String.t()]
  def notes do
    case :ets.whereis(__MODULE__) do
      :undefined -> []
      _reference -> __MODULE__ |> :ets.tab2list() |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    end
  end
end
