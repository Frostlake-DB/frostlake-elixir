defmodule Frostlake.BindingTest do
  use ExUnit.Case, async: true

  alias Frostlake.{Binding, UsageError}

  describe "scan/1" do
    test "finds positional markers and steps over the places SQL stops meaning what it says" do
      assert Binding.placeholder_count("SELECT ?, ?") == 2
      assert Binding.placeholder_count("SELECT '?'") == 0
      assert Binding.placeholder_count(~s(SELECT "a?b")) == 0
      assert Binding.placeholder_count("SELECT 1 -- ?\n") == 0
      assert Binding.placeholder_count("SELECT 1 /* ? */") == 0
      assert Binding.placeholder_count("CREATE FUNCTION f() AS $$ ? $$") == 0
      assert Binding.placeholder_count("SELECT 'it''s ?', ?") == 1
      assert Binding.placeholder_count(~S(SELECT 'a\'?', ?)) == 1
    end

    test "a $ inside an identifier does not open a dollar-quoted body" do
      assert Binding.placeholder_count("SELECT A$$B, ?") == 1
    end

    test "finds named markers, and counts a repeated one once" do
      assert Binding.placeholder_names("SELECT :a, :B, :a") == ["A", "B"]
      assert Binding.placeholder_count("SELECT :a, :b, :a") == 2
    end

    test "a cast, an assignment and a positional reference are not parameters" do
      assert Binding.placeholder_count("SELECT '1'::INT") == 0
      assert Binding.placeholder_count("LET x := 1") == 0
      assert Binding.placeholder_count("SELECT $1, :1") == 0
    end

    test "VARIANT path access is not a parameter" do
      assert Binding.placeholder_count("SELECT v:field FROM t") == 0
      assert Binding.placeholder_count("SELECT PARSE_JSON('{}'):k") == 0
      assert Binding.placeholder_count(~s(SELECT "V":k FROM t)) == 0
      assert Binding.placeholder_count("SELECT {'a': 1}:a") == 0
      assert Binding.placeholder_count("SELECT f(x):k") == 0
      assert Binding.placeholder_count("SELECT a[0]:k") == 0
    end

    test "mixing the styles reports -1 rather than a count" do
      assert Binding.placeholder_count("SELECT ?, :a") == -1
    end
  end

  describe "positional binding" do
    test "inlines the arguments in order" do
      assert Binding.substitute("SELECT ?, ?", [1, "Ada"]) == "SELECT 1, 'Ada'"
    end

    test "leaves a statement with no markers alone" do
      assert Binding.substitute("SELECT 1", []) == "SELECT 1"
    end

    test "counts in both directions" do
      assert_raise UsageError, ~r/has 2 placeholder\(s\), got 1/, fn ->
        Binding.substitute("SELECT ?, ?", [1])
      end

      assert_raise UsageError, ~r/has 1 placeholder\(s\), got 2/, fn ->
        Binding.substitute("SELECT ?", [1, 2])
      end
    end

    test "refuses a mixed statement" do
      assert_raise UsageError, ~r/not both/, fn -> Binding.substitute("SELECT ?, :a", [1, 2]) end
    end

    test "a keyword-shaped argument list still binds positionally when the markers are ?" do
      assert Binding.substitute("SELECT ?", [{:binary, <<0x01, 0xFF>>}]) == "SELECT X'01FF'"
    end
  end

  describe "named binding" do
    test "matches case-insensitively, in any order, however often a name repeats" do
      assert Binding.substitute("SELECT :a + :b + :A", %{"A" => 1, :b => 2}) ==
               "SELECT 1 + 2 + 1"

      assert Binding.substitute("SELECT :a + :b AS total", b: 40, a: 2) ==
               "SELECT 2 + 40 AS total"
    end

    test "with no arguments at all, colon references belong to the server" do
      assert Binding.substitute("EXECUTE IMMEDIATE :v", []) == "EXECUTE IMMEDIATE :v"
      assert Binding.substitute("SELECT IFF(:flag, 1, 2)", []) == "SELECT IFF(:flag, 1, 2)"
    end

    test "an unbound placeholder and an unused argument are both errors" do
      assert_raise UsageError, ~r/no argument bound for :b/, fn ->
        Binding.substitute("SELECT :a, :b", a: 1)
      end

      assert_raise UsageError, ~r/:c do not appear/, fn ->
        Binding.substitute("SELECT :a", a: 1, c: 3)
      end

      assert_raise UsageError, ~r/has no placeholders/, fn ->
        Binding.substitute("SELECT 1", a: 1)
      end
    end

    test "a map against positional markers is refused" do
      assert_raise UsageError, ~r/positional \? placeholders/, fn ->
        Binding.substitute("SELECT ?", %{a: 1})
      end
    end
  end

  describe "negatives" do
    test "go in parentheses so they cannot open a comment" do
      assert Binding.format(-7) == "(-7)"
      assert Binding.format(-2.5) == "(-2.5)"
      # Bare after a minus, -5 turned `3-?` into the comment `3--5`.
      assert Binding.substitute("SELECT 3-?", [-5]) == "SELECT 3-(-5)"
      assert Binding.substitute("SELECT 3-?", [5]) == "SELECT 3-5"
    end

    test "an empty map binds nothing, like an empty list" do
      assert Binding.substitute("SELECT ?", %{}) == "SELECT ?"
      assert Binding.substitute("SELECT :a", %{}) == "SELECT :a"
    end
  end

  describe "format/1" do
    test "renders the scalars" do
      assert Binding.format(nil) == "NULL"
      assert Binding.format(true) == "TRUE"
      assert Binding.format(false) == "FALSE"
      assert Binding.format(42) == "42"
      assert Binding.format(2.5) == "2.5"
      assert Binding.format(:nan) == "'NaN'::FLOAT"
      # 'Infinity' is the spelling the engine's cast accepts; it refuses 'Inf'.
      assert Binding.format(:infinity) == "'Infinity'::FLOAT"
      assert Binding.format(:neg_infinity) == "'-Infinity'::FLOAT"
    end

    test "keeps a big integer exact" do
      assert Binding.format(123_456_789_012_345_678_901_234_567_890) ==
               "123456789012345678901234567890"
    end

    test "escapes a string the way the engine reads one" do
      assert Binding.format("plain") == "'plain'"
      assert Binding.format("it's") == "'it''s'"
      assert Binding.format("a\\b") == ~S('a\\b')
      assert Binding.format("zażółć") == "'zażółć'"
    end

    test "renders bytes as a hex literal, and refuses to guess" do
      assert Binding.format({:binary, <<0, 1, 254, 255>>}) == "X'0001FEFF'"
      assert Binding.format({:binary, ""}) == "X''"

      assert_raise UsageError, ~r/wrap raw bytes as \{:binary, value\}/, fn ->
        Binding.format(<<0xFF, 0xFE>>)
      end
    end

    test "renders the calendar types" do
      assert Binding.format(~D[2026-08-24]) == "'2026-08-24'::DATE"
      assert Binding.format(~T[10:20:30.5]) == "'10:20:30.500000'::TIME"

      assert Binding.format(~N[2026-08-24 10:20:30]) ==
               "'2026-08-24T10:20:30.000000'::TIMESTAMP_NTZ"

      assert Binding.format(~U[2026-08-24 10:20:30.123456Z]) ==
               "'2026-08-24T10:20:30.123456+00:00'::TIMESTAMP_TZ"
    end

    test "carries a DateTime's own offset rather than dropping it" do
      value = %DateTime{
        year: 2026,
        month: 8,
        day: 24,
        hour: 12,
        minute: 0,
        second: 0,
        microsecond: {0, 0},
        time_zone: "Europe/Warsaw",
        zone_abbr: "CEST",
        utc_offset: 3600,
        std_offset: 3600
      }

      assert Binding.format(value) == "'2026-08-24T12:00:00.000000+02:00'::TIMESTAMP_TZ"
    end

    test "renders arrays and objects recursively" do
      assert Binding.format([1, "a", nil, [2]]) == "[1, 'a', NULL, [2]]"
      assert Binding.format(%{"k" => [1, 2]}) == "{'k': [1, 2]}"
      assert Binding.format(%{k: "v"}) == "{'k': 'v'}"
    end

    test "refuses a value with no SQL equivalent" do
      assert_raise UsageError, ~r/unsupported bind type/, fn -> Binding.format({1, 2}) end
      assert_raise UsageError, ~r/unsupported bind type/, fn -> Binding.format(self()) end
    end
  end

  test "a bound string cannot end the literal it sits in" do
    injected = "'; DROP TABLE users; --"
    rendered = Binding.substitute("SELECT ?", [injected])
    assert rendered == "SELECT '''; DROP TABLE users; --'"
    assert Frostlake.SQL.split_statements(rendered) == [rendered]
  end
end
