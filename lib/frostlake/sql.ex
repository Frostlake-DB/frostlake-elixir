defmodule Frostlake.SQL do
  @moduledoc """
  Lexical helpers shared by parameter binding and session-scope tracking.

  Both need to walk a statement while stepping over the places where SQL syntax
  stops meaning what it says — string literals, quoted identifiers,
  dollar-quoted bodies and comments — so both read the same scanner and cannot
  disagree about what is inside one.

  Offsets are byte offsets. Every delimiter the scanner looks for is ASCII, and
  a UTF-8 continuation byte is never one of them, so a statement full of
  multi-byte text scans exactly like one without.
  """

  @doc "Whether `byte` can appear in an unquoted identifier."
  defguard is_word_char(byte)
           when byte == ?_ or byte == ?$ or byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9

  @doc false
  def word_char?(byte) when is_word_char(byte), do: true
  def word_char?(_byte), do: false

  @doc """
  Whether a comment or a quoted region opens at `index`, and where it ends.

  Returns the index just past the region, or `-1` when `index` does not open
  one. Every walk over a statement starts here, so none of them can forget a
  case.
  """
  @spec skip_enclosure(binary(), non_neg_integer()) :: integer()
  def skip_enclosure(sql, index) do
    case :binary.at(sql, index) do
      ?' -> skip_string(sql, index)
      ?" -> skip_quoted(sql, index)
      ?$ -> if opens_dollar_quote?(sql, index), do: skip_dollar_quoted(sql, index), else: -1
      ?- -> if peek(sql, index + 1) == ?-, do: skip_line(sql, index), else: -1
      ?/ -> skip_slash(sql, index)
      _ -> -1
    end
  end

  defp skip_slash(sql, index) do
    case peek(sql, index + 1) do
      ?/ -> skip_line(sql, index)
      ?* -> skip_block_comment(sql, index)
      _ -> -1
    end
  end

  @doc """
  The index just past the single-quoted literal starting at `index`.

  Both `''` and backslash escapes end up inside the literal — a backslash always
  escapes in Frostlake's string dialect.
  """
  @spec skip_string(binary(), non_neg_integer()) :: non_neg_integer()
  def skip_string(sql, index), do: scan_string(sql, index + 1, byte_size(sql))

  defp scan_string(_sql, position, size) when position >= size, do: size

  defp scan_string(sql, position, size) do
    case :binary.at(sql, position) do
      ?\\ ->
        scan_string(sql, position + 2, size)

      ?' ->
        if peek(sql, position + 1) == ?' do
          scan_string(sql, position + 2, size)
        else
          position + 1
        end

      _ ->
        scan_string(sql, position + 1, size)
    end
  end

  @doc "The index just past the double-quoted identifier starting at `index`."
  @spec skip_quoted(binary(), non_neg_integer()) :: non_neg_integer()
  def skip_quoted(sql, index), do: scan_quoted(sql, index + 1, byte_size(sql))

  defp scan_quoted(_sql, position, size) when position >= size, do: size

  defp scan_quoted(sql, position, size) do
    if :binary.at(sql, position) == ?" do
      if peek(sql, position + 1) == ?" do
        scan_quoted(sql, position + 2, size)
      else
        position + 1
      end
    else
      scan_quoted(sql, position + 1, size)
    end
  end

  @doc """
  Whether the `$` at `index` opens a dollar-quoted body.

  A `$` is legal inside an unquoted identifier, so `A$$B` is a name rather than
  the start of a body: a real delimiter is never preceded by an identifier
  character.
  """
  @spec opens_dollar_quote?(binary(), non_neg_integer()) :: boolean()
  def opens_dollar_quote?(sql, index) do
    peek(sql, index + 1) == ?$ and (index == 0 or not word_char?(:binary.at(sql, index - 1)))
  end

  @doc """
  The index just past the `$$…$$` body starting at `index`.

  Function and procedure bodies are written this way, and their contents are not
  SQL — a `?` inside one is part of the body, never a placeholder.
  """
  @spec skip_dollar_quoted(binary(), non_neg_integer()) :: non_neg_integer()
  def skip_dollar_quoted(sql, index), do: find(sql, "$$", index + 2, 2)

  @doc "The index just past the line comment starting at `index`."
  @spec skip_line(binary(), non_neg_integer()) :: non_neg_integer()
  def skip_line(sql, index), do: find(sql, "\n", index, 1)

  @doc "The index just past the block comment starting at `index`."
  @spec skip_block_comment(binary(), non_neg_integer()) :: non_neg_integer()
  def skip_block_comment(sql, index), do: find(sql, "*/", index + 2, 2)

  defp find(sql, needle, from, width) do
    size = byte_size(sql)

    if from >= size do
      size
    else
      case :binary.match(sql, needle, scope: {from, size - from}) do
        {position, _} -> position + width
        :nomatch -> size
      end
    end
  end

  defp peek(sql, index) do
    if index < byte_size(sql), do: :binary.at(sql, index), else: -1
  end

  @doc """
  Splits a request on its top-level semicolons, leaving alone any that sit
  inside a string literal, a quoted identifier, a dollar-quoted body or a
  comment.

  A procedural block is split along with everything else, which only makes
  `changes_session_scope?/1` more willing to flag — the safe direction.
  """
  @spec split_statements(binary()) :: [binary()]
  def split_statements(sql), do: split(sql, 0, 0, byte_size(sql), [])

  defp split(sql, start, position, size, acc) when position >= size do
    Enum.reverse([binary_part(sql, start, size - start) | acc])
  end

  defp split(sql, start, position, size, acc) do
    case skip_enclosure(sql, position) do
      -1 ->
        if :binary.at(sql, position) == ?; do
          split(sql, position + 1, position + 1, size, [
            binary_part(sql, start, position - start) | acc
          ])
        else
          split(sql, start, position + 1, size, acc)
        end

      skip ->
        split(sql, start, min(skip, size), size, acc)
    end
  end

  @doc """
  Whether a request can move the session off the scope the DSN established.

  A request may hold more than one statement, and a `USE` riding behind a
  leading `SELECT` moves the scope just as surely as one standing alone, so
  every statement is examined rather than only the first.
  """
  @spec changes_session_scope?(binary()) :: boolean()
  def changes_session_scope?(sql) do
    sql |> split_statements() |> Enum.any?(&statement_changes_scope?/1)
  end

  # Only USE, the SET family, ALTER SESSION, and CREATE/DROP of a DATABASE or
  # SCHEMA move the session — CREATE TABLE and its kind leave the scope exactly
  # where it was, and counting those would mark the session dirty for every DDL
  # statement a caller runs.
  defp statement_changes_scope?(statement) do
    case leading_words(statement, 6) do
      [verb | _rest] when verb in ["USE", "SET", "UNSET"] ->
        true

      ["ALTER" | rest] ->
        names_object?(rest, ["SESSION"])

      [verb | rest] when verb in ["CREATE", "DROP"] ->
        names_object?(rest, ["DATABASE", "SCHEMA"])

      _ ->
        false
    end
  end

  # Modifiers that may sit between CREATE/DROP/ALTER and the kind of object
  # being named.
  @object_modifiers ~w(OR REPLACE TRANSIENT TEMPORARY TEMP VOLATILE LOCAL GLOBAL SECURE IF NOT EXISTS)

  # Walks the words between the verb and the object being named, stepping over
  # the modifiers that may sit between them — CREATE OR REPLACE DATABASE, DROP
  # SCHEMA IF EXISTS — and reports whether the object is one of `want`.
  defp names_object?([], _want), do: false

  defp names_object?([word | rest], want) do
    if word in @object_modifiers, do: names_object?(rest, want), else: word in want
  end

  @doc """
  Up to `count` words from the start of a statement, upper-cased, skipping
  whitespace and comments and stopping at the first thing that is not a word.
  """
  @spec leading_words(binary(), pos_integer()) :: [String.t()]
  def leading_words(statement, count), do: words(statement, 0, byte_size(statement), count, [])

  defp words(_statement, _position, _size, 0, acc), do: Enum.reverse(acc)
  defp words(_statement, position, size, _count, acc) when position >= size, do: Enum.reverse(acc)

  defp words(statement, position, size, count, acc) do
    case :binary.at(statement, position) do
      char when char in [?\s, ?\t, ?\n, ?\r] ->
        words(statement, position + 1, size, count, acc)

      # Only comments are stepped over here: a leading string literal or quoted
      # identifier means the statement does not start with a keyword at all.
      char when char in [?-, ?/] ->
        case skip_enclosure(statement, position) do
          -1 -> Enum.reverse(acc)
          skip -> words(statement, min(skip, size), size, count, acc)
        end

      char ->
        if word_char?(char) do
          stop = word_end(statement, position, size)
          word = binary_part(statement, position, stop - position)
          words(statement, stop, size, count - 1, [String.upcase(word) | acc])
        else
          Enum.reverse(acc)
        end
    end
  end

  defp word_end(statement, position, size) do
    if position < size and word_char?(:binary.at(statement, position)) do
      word_end(statement, position + 1, size)
    else
      position
    end
  end
end
