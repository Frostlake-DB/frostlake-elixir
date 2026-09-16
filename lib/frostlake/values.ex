defmodule Frostlake.Values do
  @moduledoc """
  Reading one wire cell back into an Elixir value, guided by the column's
  declared type.

  | SQL type | Elixir type |
  | --- | --- |
  | integral `NUMBER`, `INTEGER` and friends | `t:integer/0`, exact at any width |
  | fractional `NUMBER`, `FLOAT`, `DOUBLE`, `REAL` | `t:float/0` |
  | `VARCHAR` and the text types | `t:String.t/0` |
  | `BOOLEAN` | `t:boolean/0` |
  | `BINARY` | a raw binary of the decoded bytes |
  | `DATE` | `t:Date.t/0` |
  | `TIME` | `t:Time.t/0` |
  | `TIMESTAMP`, `TIMESTAMP_NTZ`, `DATETIME` | `t:NaiveDateTime.t/0` |
  | `TIMESTAMP_LTZ`, `TIMESTAMP_TZ` | `t:DateTime.t/0` — the instant, in UTC |
  | `VARIANT`, `OBJECT`, `ARRAY` | `t:String.t/0`, the engine's own rendering |

  A `FLOAT` that is not a number arrives as `:nan`, `:infinity` or
  `:neg_infinity`, because Elixir floats have no way to spell those.
  """

  alias Frostlake.{Column, JSON}

  @approximate ~w(FLOAT FLOAT4 FLOAT8 DOUBLE REAL) ++ ["DOUBLE PRECISION"]
  @integers ~w(INT INTEGER BIGINT SMALLINT TINYINT BYTEINT)
  @fixed_point ~w(NUMBER NUMERIC DECIMAL)

  @typedoc "Which temporal shape, if any, a declared type names."
  @type temporal_kind :: :none | :date | :time | :naive | :zoned

  @doc "Strips any `(p,s)` suffix, so `NUMBER(38,0)` and `NUMBER` answer alike."
  @spec base_type_name(String.t() | nil) :: String.t()
  def base_type_name(data_type) do
    name = (data_type || "") |> String.trim() |> String.upcase()

    case String.split(name, "(", parts: 2) do
      [base, _rest] -> String.trim(base)
      [base] -> base
    end
  end

  @doc "Which temporal shape, if any, a declared type names."
  @spec temporal_kind(String.t() | nil) :: temporal_kind()
  def temporal_kind(data_type) do
    case base_type_name(data_type) do
      "DATE" -> :date
      "TIME" -> :time
      name when name in ["TIMESTAMP", "TIMESTAMP_NTZ", "DATETIME"] -> :naive
      name when name in ["TIMESTAMP_LTZ", "TIMESTAMP_TZ"] -> :zoned
      _ -> :none
    end
  end

  @doc "Whether a declared type holds bytes."
  @spec binary_type?(String.t() | nil) :: boolean()
  def binary_type?(data_type), do: base_type_name(data_type) in ["BINARY", "VARBINARY"]

  @doc """
  Whether a column holds whole numbers.

  The wire carries precision and scale as their own fields — `data_type` is the
  bare word `NUMBER` — so scale is what decides, with an inline `NUMBER(p,s)`
  spelling honoured as a fallback.
  """
  @spec integral_column?(Column.t()) :: boolean()
  def integral_column?(%Column{} = column) do
    case base_type_name(column.data_type) do
      name when name in @integers -> true
      name when name in @fixed_point -> declared_scale(column) == 0
      _ -> false
    end
  end

  @doc """
  The column's scale, preferring the wire's own field and falling back to an
  inline `NUMBER(p,s)` spelling for servers that put both in the type name.
  """
  @spec declared_scale(Column.t()) :: integer()
  def declared_scale(%Column{scale: scale} = column) when scale in [nil, 0] do
    case Regex.run(~r/\(\s*\d+\s*,\s*(-?\d+)\s*\)/, column.data_type || "") do
      [_, digits] -> String.to_integer(digits)
      nil -> scale || 0
    end
  end

  def declared_scale(%Column{scale: scale}), do: scale

  @doc """
  Maps one decoded JSON cell to an Elixir value, guided by the column's declared
  type.
  """
  @spec convert_cell(term(), Column.t()) :: term()
  def convert_cell(nil, _column), do: nil

  # A VARIANT `undefined` standing alone is SQL NULL: the sentinel exists inside
  # an ARRAY and never leaks into scalar evaluation.
  def convert_cell(:undefined, _column), do: nil

  def convert_cell(raw, _column) when is_boolean(raw), do: raw
  def convert_cell(raw, _column) when raw in [:nan, :infinity, :neg_infinity], do: raw

  def convert_cell(raw, %Column{} = column) when is_binary(raw) do
    case temporal_kind(column.data_type) do
      :none ->
        cond do
          binary_type?(column.data_type) -> decode_hex(raw) || raw
          base_type_name(column.data_type) in @approximate -> float_special(raw) || raw
          true -> raw
        end

      kind ->
        parse_temporal(raw, kind) || raw
    end
  end

  def convert_cell(raw, %Column{} = column) when is_number(raw), do: convert_number(raw, column)

  # The engine renders semi-structured values as text, so these only appear if a
  # server takes to sending them structurally. Handing back the JSON text keeps
  # the column reading the same either way.
  def convert_cell(raw, _column) when is_list(raw) or is_map(raw), do: JSON.encode(raw)

  def convert_cell(raw, _column), do: raw

  # The engine renders a non-finite double as the JSON *string* "NaN",
  # "Infinity" or "-Infinity", even on a FLOAT column; on such a column that text
  # reads back as the atom it names, the same way the bare tokens do.
  defp float_special(text) do
    case text |> String.trim() |> String.downcase() do
      "nan" -> :nan
      inf when inf in ["inf", "+inf", "infinity", "+infinity"] -> :infinity
      inf when inf in ["-inf", "-infinity"] -> :neg_infinity
      _ -> nil
    end
  end

  defp convert_number(raw, %Column{} = column) do
    name = base_type_name(column.data_type)

    cond do
      name in @approximate -> raw / 1
      is_integer(raw) and (integral_column?(column) or not numeric_type?(name)) -> raw
      is_integer(raw) -> raw / 1
      true -> raw
    end
  end

  defp numeric_type?(name), do: name in @integers or name in @fixed_point or name in @approximate

  @doc """
  Reads a temporal cell, or `nil` when the text does not parse as one.

  A `DATE` and a `TIMESTAMP_NTZ` are wall clocks with no zone of their own, so
  they become a `Date` and a `NaiveDateTime` — types that have no zone either,
  and so cannot be shifted by whatever zone the host happens to be in. A
  `TIMESTAMP_TZ` names an instant, and arrives as a `DateTime` in UTC.
  """
  @spec parse_temporal(String.t(), temporal_kind()) :: term() | nil
  def parse_temporal(_text, :none), do: nil

  def parse_temporal(text, :date) do
    case Regex.run(~r/^(\d{4,})-(\d{2})-(\d{2})$/, String.trim(text)) do
      [_, year, month, day] ->
        case Date.new(int(year), int(month), int(day)) do
          {:ok, date} -> date
          _ -> nil
        end

      nil ->
        nil
    end
  end

  def parse_temporal(text, :time) do
    case Regex.run(~r/^(\d{1,2}):(\d{2}):(\d{2})(?:\.(\d+))?$/, String.trim(text)) do
      [_, hour, minute, second] -> build_time(hour, minute, second, "")
      [_, hour, minute, second, fraction] -> build_time(hour, minute, second, fraction)
      nil -> nil
    end
  end

  def parse_temporal(text, :naive), do: parse_naive(String.trim(text))

  def parse_temporal(text, :zoned) do
    trimmed = String.trim(text)

    case Regex.run(
           ~r/^(\d{4,}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?)\s*(Z|[+-]\d{2}:?\d{2})$/,
           trimmed
         ) do
      [_, stamp, zone] -> zoned(stamp, zone)
      nil -> parse_naive(trimmed)
    end
  end

  defp zoned(stamp, zone) do
    case parse_naive(stamp) do
      nil ->
        nil

      naive ->
        # A DateTime is the instant, so the offset is applied rather than kept:
        # the same choice DateTime.from_iso8601/1 makes for a string carrying one.
        naive
        |> NaiveDateTime.add(-offset_seconds(zone), :second)
        |> DateTime.from_naive!("Etc/UTC")
    end
  end

  defp offset_seconds("Z"), do: 0

  defp offset_seconds(<<sign, rest::binary>>) do
    [hours, minutes] =
      case String.split(rest, ":") do
        [hours, minutes] -> [hours, minutes]
        [<<hours::binary-size(2), minutes::binary-size(2)>>] -> [hours, minutes]
      end

    seconds = int(hours) * 3600 + int(minutes) * 60
    if sign == ?-, do: -seconds, else: seconds
  end

  defp parse_naive(text) do
    case Regex.run(
           ~r/^(\d{4,})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?$/,
           text
         ) do
      [_, year, month, day, hour, minute, second] ->
        build_naive(year, month, day, hour, minute, second, "")

      [_, year, month, day, hour, minute, second, fraction] ->
        build_naive(year, month, day, hour, minute, second, fraction)

      nil ->
        nil
    end
  end

  defp build_naive(year, month, day, hour, minute, second, fraction) do
    case NaiveDateTime.new(
           int(year),
           int(month),
           int(day),
           int(hour),
           int(minute),
           int(second),
           microsecond(fraction)
         ) do
      {:ok, naive} -> naive
      _ -> nil
    end
  end

  defp build_time(hour, minute, second, fraction) do
    case Time.new(int(hour), int(minute), int(second), microsecond(fraction)) do
      {:ok, time} -> time
      _ -> nil
    end
  end

  # Anything finer than a microsecond is rounded away, which is as much as
  # Elixir's calendar types hold; the precision is kept alongside so a value that
  # arrived with milliseconds prints with milliseconds.
  defp microsecond(""), do: {0, 0}

  defp microsecond(digits) do
    precision = min(byte_size(digits), 6)
    padded = digits |> binary_part(0, precision) |> String.pad_trailing(6, "0")
    {String.to_integer(padded), precision}
  end

  defp int(digits), do: String.to_integer(digits)

  @doc """
  Decodes the hex text the engine renders `BINARY` as, or `nil` when the text is
  not hex after all.

  Anything else is not the driver's to reinterpret: silently dropping a stray
  character would turn a value the caller can still read into one they cannot.
  """
  @spec decode_hex(String.t()) :: binary() | nil
  def decode_hex(""), do: ""

  def decode_hex(text) do
    case Base.decode16(text, case: :mixed) do
      {:ok, bytes} -> bytes
      :error -> nil
    end
  end
end
