defmodule Frostlake.JSON do
  @moduledoc """
  The driver's own JSON codec.

  It exists because the wire is not quite JSON. The engine spells Snowflake's
  VARIANT `undefined` as a bare `undefined` token — JSON has no word for it, and
  `[1,undefined,2]` is the text every other Frostlake driver reports — and a
  binary float that is not a number arrives as a bare `NaN`, `Infinity` or
  `-Infinity`. A strict parser rejects all four outright, which would turn a
  readable cell into a transport failure.

  Numbers keep their exact value: an integer literal decodes to an Elixir
  integer at any width, so a `NUMBER(38,0)` past 64 bits survives intact rather
  than rounding through a float.

  Decoded shapes are plain Elixir terms — maps with binary keys, lists,
  binaries, integers, floats, booleans, `nil` — plus the four atoms
  `:undefined`, `:nan`, `:infinity` and `:neg_infinity` for the tokens above.
  """

  @max_depth 256

  @doc """
  Decodes a JSON document.

  Returns `{:ok, term}` or `{:error, message}`, where the message names the
  offset and quotes its neighbourhood — "malformed JSON at offset 0" on its own
  does not say which body came back.
  """
  @spec decode(binary()) :: {:ok, term()} | {:error, String.t()}
  def decode(json) when is_binary(json) do
    {term, rest} = value(skip_whitespace(json), json, 0)

    case skip_whitespace(rest) do
      "" -> {:ok, term}
      trailing -> fail(json, trailing, "unexpected trailing content")
    end
  rescue
    # A body is untrusted input; whatever the reader trips over inside it is a
    # malformed document, never a crash of the process reading it.
    e -> {:error, "malformed JSON: " <> Exception.message(e)}
  catch
    :throw, {__MODULE__, message} -> {:error, message}
  end

  @doc "Same as `decode/1`, but raises `ArgumentError` on malformed input."
  @spec decode!(binary()) :: term()
  def decode!(json) do
    case decode(json) do
      {:ok, term} -> term
      {:error, message} -> raise ArgumentError, message
    end
  end

  @doc """
  Encodes a term as JSON text.

  The four wire atoms above encode back to the bare tokens they came from, so a
  value that arrived as `undefined` renders as `undefined` again.
  """
  @spec encode(term()) :: String.t()
  def encode(term), do: IO.iodata_to_binary(encode_to_iodata(term))

  @doc "Same as `encode/1`, without flattening the result."
  @spec encode_to_iodata(term()) :: iodata()
  def encode_to_iodata(nil), do: "null"
  def encode_to_iodata(true), do: "true"
  def encode_to_iodata(false), do: "false"
  def encode_to_iodata(:undefined), do: "undefined"
  def encode_to_iodata(:nan), do: "NaN"
  def encode_to_iodata(:infinity), do: "Infinity"
  def encode_to_iodata(:neg_infinity), do: "-Infinity"
  def encode_to_iodata(value) when is_integer(value), do: Integer.to_string(value)
  def encode_to_iodata(value) when is_float(value), do: Float.to_string(value)
  def encode_to_iodata(value) when is_binary(value), do: encode_string(value)
  def encode_to_iodata(value) when is_atom(value), do: encode_string(Atom.to_string(value))

  def encode_to_iodata(value) when is_list(value) do
    ["[", value |> Enum.map(&encode_to_iodata/1) |> Enum.intersperse(","), "]"]
  end

  def encode_to_iodata(value) when is_map(value) do
    members =
      value
      |> Enum.map(fn {key, member} -> [encode_key(key), ":", encode_to_iodata(member)] end)
      |> Enum.intersperse(",")

    ["{", members, "}"]
  end

  defp encode_key(key) when is_binary(key), do: encode_string(key)
  defp encode_key(key) when is_atom(key), do: encode_string(Atom.to_string(key))
  defp encode_key(key), do: encode_string(to_string(key))

  @doc "Encodes one string as a JSON string literal, quotes included."
  @spec encode_string(binary()) :: iodata()
  def encode_string(text) when is_binary(text), do: [?", escape(text, text, 0, []), ?"]

  # Copies the input in runs: only a character JSON forbids raw interrupts the
  # scan, so an ordinary payload is one slice rather than a byte-by-byte rebuild.
  # `run` is the input from the current run's first byte, `size` its length.
  defp escape("", run, size, acc), do: [acc, binary_part(run, 0, size)]

  defp escape(<<char, rest::binary>>, run, size, acc) when char in [?", ?\\] or char < 0x20 do
    escape(rest, rest, 0, [acc, binary_part(run, 0, size), escaped(char)])
  end

  defp escape(<<_::utf8, rest::binary>> = text, run, size, acc) do
    escape(rest, run, size + byte_size(text) - byte_size(rest), acc)
  end

  defp escape(<<_byte, rest::binary>>, run, size, acc) do
    # Not valid UTF-8. Passing the byte through would produce a body no parser
    # can read, so it becomes the replacement character.
    escape(rest, rest, 0, [acc, binary_part(run, 0, size), "\\ufffd"])
  end

  defp escaped(?"), do: "\\\""
  defp escaped(?\\), do: "\\\\"
  defp escaped(?\n), do: "\\n"
  defp escaped(?\r), do: "\\r"
  defp escaped(?\t), do: "\\t"
  defp escaped(?\b), do: "\\b"
  defp escaped(?\f), do: "\\f"

  defp escaped(char) do
    "\\u" <> (char |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0"))
  end

  ## Decoding

  defp value(_json, original, depth) when depth > @max_depth do
    fail(original, "", "nested more than #{@max_depth} deep")
  end

  defp value(<<?{, rest::binary>>, original, depth) do
    object(skip_whitespace(rest), original, depth, [])
  end

  defp value(<<?[, rest::binary>>, original, depth) do
    array(skip_whitespace(rest), original, depth, [])
  end

  defp value(<<?", rest::binary>>, original, _depth), do: string(rest, original, [])
  defp value(<<"true", rest::binary>>, _original, _depth), do: {true, rest}
  defp value(<<"false", rest::binary>>, _original, _depth), do: {false, rest}
  defp value(<<"null", rest::binary>>, _original, _depth), do: {nil, rest}

  # Not JSON, but what the engine writes for a VARIANT `undefined` and for the
  # floats IEEE has words for and JSON does not.
  defp value(<<"undefined", rest::binary>>, _original, _depth), do: {:undefined, rest}
  defp value(<<"NaN", rest::binary>>, _original, _depth), do: {:nan, rest}
  defp value(<<"Infinity", rest::binary>>, _original, _depth), do: {:infinity, rest}
  defp value(<<"-Infinity", rest::binary>>, _original, _depth), do: {:neg_infinity, rest}

  defp value(<<char, _::binary>> = json, original, _depth) when char in ?0..?9 or char == ?- do
    number(json, original)
  end

  defp value("", original, _depth), do: fail(original, "", "input ended early")
  defp value(json, original, _depth), do: fail(original, json, "unexpected character")

  defp object(<<?}, rest::binary>>, _original, _depth, []), do: {%{}, rest}

  defp object(<<?", rest::binary>>, original, depth, acc) do
    {key, rest} = string(rest, original, [])

    case skip_whitespace(rest) do
      <<?:, rest::binary>> ->
        {member, rest} = value(skip_whitespace(rest), original, depth + 1)
        acc = [{key, member} | acc]

        case skip_whitespace(rest) do
          <<?,, rest::binary>> -> object(skip_whitespace(rest), original, depth, acc)
          <<?}, rest::binary>> -> {Map.new(acc), rest}
          "" -> fail(original, "", "input ended inside an object")
          rest -> fail(original, rest, "expected , or } in an object")
        end

      rest ->
        fail(original, rest, "expected : after a member name")
    end
  end

  defp object("", original, _depth, _acc), do: fail(original, "", "input ended inside an object")
  defp object(rest, original, _depth, _acc), do: fail(original, rest, "expected a member name")

  defp array(<<?], rest::binary>>, _original, _depth, []), do: {[], rest}

  defp array(json, original, depth, acc) do
    {element, rest} = value(json, original, depth + 1)
    acc = [element | acc]

    case skip_whitespace(rest) do
      <<?,, rest::binary>> -> array(skip_whitespace(rest), original, depth, acc)
      <<?], rest::binary>> -> {Enum.reverse(acc), rest}
      "" -> fail(original, "", "input ended inside an array")
      rest -> fail(original, rest, "expected , or ] in an array")
    end
  end

  # Scans to the next quote or backslash rather than one byte at a time, so an
  # ordinary string is copied in a single slice.
  defp string(json, original, acc) do
    case :binary.match(json, ["\"", "\\"]) do
      :nomatch ->
        fail(original, "", "input ended inside a string")

      {position, 1} ->
        <<chunk::binary-size(^position), char, rest::binary>> = json

        case char do
          ?" -> {IO.iodata_to_binary(Enum.reverse([chunk | acc])), rest}
          ?\\ -> unescape(rest, original, [chunk | acc])
        end
    end
  end

  defp unescape(<<?u, hex::binary-size(4), rest::binary>>, original, acc) do
    # `Integer.parse` takes a leading sign, and a negative code point cannot be
    # built into a binary — an ArgumentError, not the throw this reader uses —
    # so the four have to be hex digits before they are parsed.
    if hex_digits?(hex) do
      unescape_codepoint(String.to_integer(hex, 16), rest, original, acc)
    else
      fail(original, rest, "invalid \\u escape")
    end
  end

  defp unescape(<<char, rest::binary>>, original, acc) do
    literal =
      case char do
        ?" -> "\""
        ?\\ -> "\\"
        ?/ -> "/"
        ?b -> "\b"
        ?f -> "\f"
        ?n -> "\n"
        ?r -> "\r"
        ?t -> "\t"
        _ -> fail(original, rest, "invalid escape")
      end

    string(rest, original, [literal | acc])
  end

  defp unescape("", original, _acc), do: fail(original, "", "input ended inside an escape")

  defp hex_digits?(<<a, b, c, d>>),
    do: hex_digit?(a) and hex_digit?(b) and hex_digit?(c) and hex_digit?(d)

  defp hex_digit?(c), do: c in ?0..?9 or c in ?a..?f or c in ?A..?F

  # A code point above the basic plane arrives as a surrogate pair; the low half
  # is meaningless on its own, so the two are joined before decoding.
  defp unescape_codepoint(high, rest, original, acc) when high in 0xD800..0xDBFF do
    case rest do
      <<"\\u", hex::binary-size(4), tail::binary>> ->
        case Integer.parse(hex, 16) do
          {low, ""} when low in 0xDC00..0xDFFF ->
            code = 0x10000 + (high - 0xD800) * 0x400 + (low - 0xDC00)
            string(tail, original, [<<code::utf8>> | acc])

          _ ->
            string(rest, original, ["�" | acc])
        end

      _ ->
        string(rest, original, ["�" | acc])
    end
  end

  # An unpaired low surrogate is not a character; replacing it keeps the rest of
  # the string readable.
  defp unescape_codepoint(code, rest, original, acc) when code in 0xDC00..0xDFFF do
    string(rest, original, ["�" | acc])
  end

  defp unescape_codepoint(code, rest, original, acc) do
    string(rest, original, [<<code::utf8>> | acc])
  end

  defp number(json, original) do
    size = number_size(json, 0)
    <<text::binary-size(^size), rest::binary>> = json

    case Integer.parse(text) do
      {value, ""} ->
        {value, rest}

      _ ->
        case Float.parse(text) do
          {value, ""} -> {exact_whole(text) || value, rest}
          _ -> fail(original, json, "malformed number")
        end
    end
  end

  @number_shape ~r/^(-)?(\d+)(?:\.(\d+))?(?:[eE]([+-]?\d+))?$/

  # A whole value the engine spelled with an exponent or a zero fraction —
  # `1.23E+5`, `12.000`, the way a BigDecimal with a negative scale prints — is
  # still an integer, and reading it as a float would round a wide one.
  defp exact_whole(text) do
    case Regex.run(@number_shape, text) do
      nil ->
        nil

      [_, sign, whole | rest] ->
        fraction = Enum.at(rest, 0) || ""
        exponent = String.to_integer(Enum.at(rest, 1) || "0")
        digits = whole <> fraction
        scale = exponent - String.length(fraction)

        {digits, scale} =
          if scale < 0 do
            # Whole only if every digit right of the point is a zero.
            keep = String.length(digits) + scale
            {kept, dropped} = if keep <= 0, do: {"0", digits}, else: String.split_at(digits, keep)
            if String.trim(dropped, "0") == "", do: {kept, 0}, else: {nil, 0}
          else
            {digits, scale}
          end

        cond do
          digits == nil -> nil
          String.length(digits) + scale > 80 -> nil
          sign == "-" -> -String.to_integer(digits) * Integer.pow(10, scale)
          true -> String.to_integer(digits) * Integer.pow(10, scale)
        end
    end
  end

  defp number_size(<<char, rest::binary>>, size)
       when char in ?0..?9 or char in [?-, ?+, ?., ?e, ?E] do
    number_size(rest, size + 1)
  end

  defp number_size(_rest, size), do: size

  defp skip_whitespace(<<char, rest::binary>>) when char in [?\s, ?\t, ?\n, ?\r] do
    skip_whitespace(rest)
  end

  defp skip_whitespace(json), do: json

  defp fail(original, rest, what) do
    offset = byte_size(original) - byte_size(rest)
    from = max(offset - 24, 0)
    near = binary_part(original, from, min(48, byte_size(original) - from))
    throw({__MODULE__, "malformed JSON at offset #{offset}: #{what} (near #{near})"})
  end
end
