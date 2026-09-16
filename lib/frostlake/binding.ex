defmodule Frostlake.Binding do
  @moduledoc """
  Client-side parameter binding.

  The HTTP protocol has no server-side binding, so parameters are inlined into
  the statement here — the same thing Frostlake's JDBC driver does, with the same
  rules. A `?` inside a string literal, quoted identifier, `$$…$$` body or
  comment is never a placeholder, and the argument count has to match exactly
  whenever arguments are supplied. With none at all the markers pass through to
  the server: a `?` is then a Snowflake Scripting cursor placeholder bound by
  `OPEN c USING (...)`, and `:name` a Scripting variable.
  """

  import Frostlake.SQL, only: [is_word_char: 1]

  alias Frostlake.{SQL, UsageError}

  @typedoc """
  One bind site: `{start, stop, name}` as byte offsets, with `name` `nil` for a
  positional `?` and the upper-cased name for a `:name`.
  """
  @type placeholder :: {non_neg_integer(), non_neg_integer(), String.t() | nil}

  @doc """
  Finds every bind site in a statement, skipping string literals, quoted
  identifiers, dollar-quoted bodies and comments.

  Counting and substitution both read this one scan, so they cannot disagree
  about what is a placeholder.
  """
  @spec scan(binary()) :: [placeholder()]
  def scan(sql), do: scan(sql, 0, byte_size(sql), [])

  defp scan(_sql, position, size, acc) when position >= size, do: Enum.reverse(acc)

  defp scan(sql, position, size, acc) do
    case SQL.skip_enclosure(sql, position) do
      -1 -> scan_marker(sql, position, size, acc)
      skip -> scan(sql, min(skip, size), size, acc)
    end
  end

  defp scan_marker(sql, position, size, acc) do
    case :binary.at(sql, position) do
      ?? -> scan(sql, position + 1, size, [{position, position + 1, nil} | acc])
      ?: -> scan_colon(sql, position, size, acc)
      _ -> scan(sql, position + 1, size, acc)
    end
  end

  defp scan_colon(sql, position, size, acc) do
    cond do
      # `::` is a cast and `:=` an assignment; neither introduces a parameter.
      at(sql, position + 1, size) in [?:, ?=] ->
        scan(sql, position + 2, size, acc)

      # A colon ADJACENT to the end of an expression — an identifier character,
      # `)`, `]`, `}`, `"` or `'` — is Snowflake's VARIANT path access (`v:field`,
      # `PARSE_JSON('…'):k`, `{'a': 1}:a`, `"V":k`), not a parameter: a bind
      # marker follows an operator, comma or keyword boundary instead.
      position > 0 and adjacent_to_expression?(:binary.at(sql, position - 1)) ->
        scan(sql, position + 1, size, acc)

      true ->
        stop = name_end(sql, position + 1, size)
        first = at(sql, position + 1, size)

        # A leading digit means a positional reference (`:1`), not a name.
        if stop > position + 1 and first not in ?0..?9 do
          name = binary_part(sql, position + 1, stop - position - 1)
          scan(sql, stop, size, [{position, stop, String.upcase(name)} | acc])
        else
          scan(sql, position + 1, size, acc)
        end
    end
  end

  defp adjacent_to_expression?(byte) when is_word_char(byte), do: true
  defp adjacent_to_expression?(byte), do: byte in [?), ?], ?}, ?", ?']

  defp name_end(sql, position, size) do
    if position < size and SQL.word_char?(:binary.at(sql, position)) do
      name_end(sql, position + 1, size)
    else
      position
    end
  end

  defp at(sql, position, size) do
    if position < size, do: :binary.at(sql, position), else: -1
  end

  @doc """
  How many arguments a statement expects.

  Named placeholders count once each however often they appear. A statement
  mixing the two styles reports `-1`, so a caller checking the count leaves the
  real complaint to `substitute/2`.
  """
  @spec placeholder_count(binary()) :: integer()
  def placeholder_count(sql) do
    {positional, names} = tally(sql)

    cond do
      positional > 0 and names != [] -> -1
      names != [] -> length(names)
      true -> positional
    end
  end

  @doc """
  The parameter names a statement carries, upper-cased, in order of first
  appearance.
  """
  @spec placeholder_names(binary()) :: [String.t()]
  def placeholder_names(sql), do: sql |> tally() |> elem(1)

  defp tally(sql) do
    sql
    |> scan()
    |> Enum.reduce({0, []}, fn
      {_, _, nil}, {positional, names} ->
        {positional + 1, names}

      {_, _, name}, {positional, names} ->
        {positional, if(name in names, do: names, else: names ++ [name])}
    end)
  end

  @doc """
  Inlines `parameters` into `sql` and returns the statement as it will be sent.

  A list binds positional `?` markers in order; a map or keyword list binds
  `:name` markers, case-insensitively and in any order. Raises
  `Frostlake.UsageError` when the two do not line up.
  """
  @spec substitute(binary(), list() | map()) :: binary()
  def substitute(sql, parameters) when is_list(parameters) do
    # Which style the STATEMENT uses decides how the list is read, not what the
    # list looks like: `[{:binary, <<1>>}]` is one positional argument and also a
    # perfectly good keyword list, and only the statement can settle it.
    if named_markers_only?(sql) and Keyword.keyword?(parameters) and parameters != [] do
      substitute_named(sql, Map.new(parameters))
    else
      substitute_positional(sql, parameters)
    end
  end

  # An empty map means the same as an empty list: nothing bound, everything the
  # server's.
  def substitute(sql, parameters) when is_map(parameters) and map_size(parameters) == 0 do
    substitute_positional(sql, [])
  end

  def substitute(sql, parameters) when is_map(parameters) and not is_struct(parameters) do
    substitute_named(sql, parameters)
  end

  def substitute(_sql, parameters) do
    raise UsageError,
      message:
        "parameters must be a list (for ? markers) or a map or keyword list " <>
          "(for :name markers), got #{inspect(parameters)}"
  end

  # No positional marker anywhere — which includes a statement with no markers at
  # all, where a keyword list is still named-looking and deserves the named
  # complaint rather than a count of question marks.
  defp named_markers_only?(sql) do
    Enum.all?(scan(sql), fn {_, _, name} -> name != nil end)
  end

  @doc """
  Inlines positional `?` placeholders with formatted literals.
  """
  @spec substitute_positional(binary(), list()) :: binary()
  def substitute_positional(sql, parameters) do
    sites = scan(sql)
    named = Enum.count(sites, fn {_, _, name} -> name != nil end)

    if named > 0 do
      if named != length(sites) do
        raise UsageError, message: "a statement may use ? or :name placeholders, not both"
      end

      # With no arguments at all, the colon references are the SERVER's —
      # Snowflake Scripting variables (`EXECUTE IMMEDIATE :v`, `IFF(:flag, …)`)
      # — and the statement passes through verbatim. Named client binds exist
      # only when named arguments are supplied.
      if parameters == [] do
        sql
      else
        raise UsageError,
          message:
            "the statement uses :name placeholders; pass a map or keyword list " <>
              "instead of a list"
      end
    else
      # Symmetrically, with no arguments at all the ? marks are the SERVER's — a
      # Snowflake Scripting cursor placeholder bound by `OPEN c USING (...)` — and
      # the statement passes through verbatim. Positional client binds exist only
      # when arguments are supplied.
      cond do
        parameters == [] ->
          sql

        length(sites) != length(parameters) ->
          raise UsageError,
            message:
              "the statement has #{length(sites)} placeholder(s), " <>
                "got #{length(parameters)} argument(s)"

        true ->
          literals =
            Enum.zip_with(sites, parameters, fn site, value -> {site, format(value)} end)

          splice(sql, literals)
      end
    end
  end

  @doc """
  Inlines `:name` placeholders with formatted literals.

  Names match case-insensitively, and order does not matter. An argument that no
  placeholder mentions is an error rather than a silent no-op — it almost always
  means the name was misspelled on one side or the other.
  """
  @spec substitute_named(binary(), map()) :: binary()
  def substitute_named(sql, parameters) do
    sites = scan(sql)
    positional = Enum.count(sites, fn {_, _, name} -> name == nil end)

    if positional > 0 do
      if positional != length(sites) do
        raise UsageError, message: "a statement may use ? or :name placeholders, not both"
      end

      raise UsageError,
        message: "the statement uses positional ? placeholders; pass a list instead of a map"
    end

    values =
      Map.new(parameters, fn {key, value} -> {key |> to_string() |> String.upcase(), value} end)

    if sites == [] do
      if map_size(values) == 0 do
        sql
      else
        raise UsageError,
          message: "the statement has no placeholders, got #{map_size(values)} named argument(s)"
      end
    else
      rendered =
        splice(
          sql,
          Enum.map(sites, fn {_, _, name} = site ->
            case Map.fetch(values, name) do
              {:ok, value} ->
                {site, format(value)}

              :error ->
                raise UsageError, message: "no argument bound for :#{String.downcase(name)}"
            end
          end)
        )

      used = MapSet.new(sites, fn {_, _, name} -> name end)

      case values |> Map.keys() |> Enum.reject(&MapSet.member?(used, &1)) |> Enum.sort() do
        [] ->
          rendered

        unused ->
          raise UsageError,
            message:
              "argument(s) #{Enum.map_join(unused, ", ", &":#{String.downcase(&1)}")} " <>
                "do not appear in the statement"
      end
    end
  end

  # Copies the statement around its bind sites, dropping each marker and putting
  # its literal in place.
  defp splice(sql, literals) do
    {chunks, cursor} =
      Enum.reduce(literals, {[], 0}, fn {{start, stop, _name}, literal}, {acc, cursor} ->
        {[literal, binary_part(sql, cursor, start - cursor) | acc], stop}
      end)

    tail = binary_part(sql, cursor, byte_size(sql) - cursor)
    IO.iodata_to_binary(Enum.reverse([tail | chunks]))
  end

  @doc """
  Renders one value as the SQL literal that stands in for it.

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
  """
  @spec format(term()) :: String.t()
  def format(nil), do: "NULL"
  def format(true), do: "TRUE"
  def format(false), do: "FALSE"
  def format(value) when is_integer(value), do: numeral(Integer.to_string(value))
  def format(value) when is_float(value), do: numeral(Float.to_string(value))

  # Elixir has no float for these, so they travel as the text the engine casts —
  # in the engine's own spellings; the shorter 'Inf' is refused.
  def format(:nan), do: "'NaN'::FLOAT"
  def format(:infinity), do: "'Infinity'::FLOAT"
  def format(:neg_infinity), do: "'-Infinity'::FLOAT"

  def format({:binary, bytes}) when is_binary(bytes), do: "X'#{Base.encode16(bytes)}'"

  def format(%Date{} = value), do: "'#{Date.to_iso8601(value)}'::DATE"
  def format(%Time{} = value), do: "'#{time_text(value)}'::TIME"

  def format(%NaiveDateTime{} = value) do
    "'#{Date.to_iso8601(value)}T#{time_text(value)}'::TIMESTAMP_NTZ"
  end

  # A %DateTime{} always knows its offset, so it maps to TIMESTAMP_TZ. Casting
  # to TIMESTAMP_NTZ here would silently discard that offset, and two values
  # naming the same instant would then store as two different timestamps.
  def format(%DateTime{} = value) do
    "'#{Date.to_iso8601(value)}T#{time_text(value)}#{offset_text(value)}'::TIMESTAMP_TZ"
  end

  def format(%module{} = value) do
    if module == Decimal and Code.ensure_loaded?(module) do
      apply(module, :to_string, [value, :normal])
    else
      raise UsageError, message: "unsupported bind type #{inspect(module)}"
    end
  end

  def format(value) when is_binary(value) do
    unless String.valid?(value) do
      raise UsageError,
        message:
          "a string bind value must be valid UTF-8; " <>
            "wrap raw bytes as {:binary, value} to send them as BINARY"
    end

    encode_string_literal(value)
  end

  def format(value) when is_map(value) do
    members =
      Enum.map_join(value, ", ", fn {key, member} ->
        "#{encode_string_literal(object_key(key))}: #{format(member)}"
      end)

    "{#{members}}"
  end

  def format(value) when is_list(value), do: "[#{Enum.map_join(value, ", ", &format/1)}]"

  def format(value) do
    raise UsageError, message: "unsupported bind type #{inspect(value)}"
  end

  # A negative numeral goes in parentheses: spliced straight after a minus it
  # would otherwise open a `--` comment, so `SELECT 3-?` bound -5 became
  # `SELECT 3--5`, which the engine reads as `SELECT 3`.
  defp numeral(<<?-, _::binary>> = text), do: "(" <> text <> ")"
  defp numeral(text), do: text

  defp object_key(key) when is_binary(key), do: key
  defp object_key(key) when is_atom(key), do: Atom.to_string(key)

  defp object_key(key) do
    raise UsageError, message: "an object key must be a string or atom, got #{inspect(key)}"
  end

  @doc """
  Mirrors the engine's canonical literal encoder: backslashes doubled (a
  backslash always escapes), quotes doubled.
  """
  @spec encode_string_literal(String.t()) :: String.t()
  def encode_string_literal(text) do
    "'" <> (text |> String.replace("\\", "\\\\") |> String.replace("'", "''")) <> "'"
  end

  defp time_text(value) do
    {microseconds, _precision} = value.microsecond

    [value.hour, value.minute, value.second]
    |> Enum.map_join(":", &pad(&1, 2))
    |> Kernel.<>("." <> pad(microseconds, 6))
  end

  defp offset_text(%DateTime{} = value) do
    total = div(value.utc_offset + value.std_offset, 60)
    sign = if total < 0, do: "-", else: "+"
    total = abs(total)
    "#{sign}#{pad(div(total, 60), 2)}:#{pad(rem(total, 60), 2)}"
  end

  defp pad(value, width), do: value |> Integer.to_string() |> String.pad_leading(width, "0")
end
