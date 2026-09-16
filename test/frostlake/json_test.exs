defmodule Frostlake.JSONTest do
  use ExUnit.Case, async: true

  alias Frostlake.JSON

  doctest Frostlake.JSON

  describe "decode/1" do
    test "reads the primitives" do
      assert JSON.decode("null") == {:ok, nil}
      assert JSON.decode("true") == {:ok, true}
      assert JSON.decode("false") == {:ok, false}
      assert JSON.decode(~s("text")) == {:ok, "text"}
      assert JSON.decode("[]") == {:ok, []}
      assert JSON.decode("{}") == {:ok, %{}}
    end

    test "keeps an integer exact past what a float could hold" do
      assert {:ok, value} = JSON.decode("12345678901234567890123456789012345678")
      assert value == 12_345_678_901_234_567_890_123_456_789_012_345_678
      assert is_integer(value)
    end

    test "reads fractional and exponent numbers as floats" do
      assert JSON.decode("2.5") == {:ok, 2.5}
      assert JSON.decode("-0.125") == {:ok, -0.125}
      assert JSON.decode("1e3") == {:ok, 1.0e3}
      assert JSON.decode("-1.5E-3") == {:ok, -1.5e-3}
    end

    test "reads the bare tokens the engine writes for VARIANT undefined and the odd floats" do
      assert JSON.decode("[1,undefined,2]") == {:ok, [1, :undefined, 2]}
      assert JSON.decode("[NaN,Infinity,-Infinity]") == {:ok, [:nan, :infinity, :neg_infinity]}
      # A whole value in an exponent or zero-fraction spelling stays an integer.
      assert JSON.decode("1E+3") == {:ok, 1000}
      assert JSON.decode("1.2E+5") == {:ok, 120_000}
      assert JSON.decode("12.000") == {:ok, 12}
      assert JSON.decode("-0.0") == {:ok, 0}
      assert JSON.decode("5E-3") == {:ok, 0.005}
      assert JSON.decode("1.25E+1") == {:ok, 12.5}
      assert JSON.decode("123456789012345678901234567890E+2") ==
               {:ok, 12_345_678_901_234_567_890_123_456_789_000}
      # A signed "hex" escape must be a malformed document, not a crash.
      assert {:error, _} = JSON.decode(~S("\u-001"))
      assert {:error, _} = JSON.decode(~S("\u+041"))
    end

    test "reads nested structures" do
      json = ~s({"a":[1,{"b":null}],"c":{"d":[true,false]}})

      assert {:ok, %{"a" => [1, %{"b" => nil}], "c" => %{"d" => [true, false]}}} =
               JSON.decode(json)
    end

    test "reads string escapes" do
      assert JSON.decode(~s("a\\"b")) == {:ok, ~s(a"b)}
      assert JSON.decode(~s("a\\\\b")) == {:ok, ~S(a\b)}
      assert JSON.decode(~s("a\\nb")) == {:ok, "a\nb"}
      assert JSON.decode(~s("\\u00e9")) == {:ok, "é"}
      assert JSON.decode(~s("\\u0041\\u0042")) == {:ok, "AB"}
    end

    test "joins a surrogate pair into one code point" do
      assert JSON.decode(~s("\\ud83d\\ude00")) == {:ok, "😀"}
    end

    test "replaces an unpaired surrogate rather than failing" do
      assert {:ok, "�"} = JSON.decode(~s("\\ud83d"))
    end

    test "passes multi-byte text through untouched" do
      assert JSON.decode(~s({"k":"zażółć gęślą jaźń"})) == {:ok, %{"k" => "zażółć gęślą jaźń"}}
    end

    test "names the offset and quotes the neighbourhood when the body is not JSON" do
      assert {:error, message} = JSON.decode("<html>Bad Gateway</html>")
      assert message =~ "malformed JSON at offset 0"
      assert message =~ "<html>Bad Gateway"
    end

    test "rejects trailing content" do
      assert {:error, message} = JSON.decode("{} {}")
      assert message =~ "unexpected trailing content"
    end

    test "rejects an unfinished document" do
      assert {:error, _} = JSON.decode(~s({"a":))
      assert {:error, _} = JSON.decode(~s({"a"))
      assert {:error, _} = JSON.decode("[1,")
      assert {:error, _} = JSON.decode(~s("unterminated))
    end

    test "refuses a document nested past the depth limit" do
      deep = String.duplicate("[", 300) <> String.duplicate("]", 300)
      assert {:error, message} = JSON.decode(deep)
      assert message =~ "nested more than"
    end

    test "decode!/1 raises where decode/1 reports" do
      assert_raise ArgumentError, ~r/malformed JSON/, fn -> JSON.decode!("nope") end
    end
  end

  describe "encode/1" do
    test "writes the primitives" do
      assert JSON.encode(nil) == "null"
      assert JSON.encode(true) == "true"
      assert JSON.encode(42) == "42"
      assert JSON.encode(2.5) == "2.5"
      assert JSON.encode("text") == ~s("text")
      assert JSON.encode([]) == "[]"
      assert JSON.encode(%{}) == "{}"
    end

    test "escapes what JSON forbids raw" do
      assert JSON.encode(~s(a"b)) == ~s("a\\"b")
      assert JSON.encode("a\\b") == ~s("a\\\\b")
      assert JSON.encode("a\nb\tc") == ~s("a\\nb\\tc")
      assert JSON.encode(<<0>>) == ~s("\\u0000")
    end

    test "leaves valid UTF-8 alone" do
      assert JSON.encode("zażółć") == ~s("zażółć")
    end

    test "replaces a byte that is not UTF-8 rather than emitting an unreadable body" do
      assert JSON.encode(<<0xFF>>) == ~s("\\ufffd")
    end

    test "writes the wire's own bare tokens back" do
      assert JSON.encode([:undefined, :nan, :infinity, :neg_infinity]) ==
               "[undefined,NaN,Infinity,-Infinity]"
    end

    test "round-trips the shape of a request payload" do
      payload = %{"sql" => "SELECT 'a\nb'", "sessionId" => "abc", "autoCommit" => true}
      assert {:ok, ^payload} = payload |> JSON.encode() |> JSON.decode()
    end
  end
end
