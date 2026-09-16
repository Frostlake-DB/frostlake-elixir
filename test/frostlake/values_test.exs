defmodule Frostlake.ValuesTest do
  use ExUnit.Case, async: true

  alias Frostlake.{Column, JSON, Result, Values}

  defp column(type, opts \\ []) do
    %Column{
      name: Keyword.get(opts, :name, "C"),
      data_type: type,
      precision: Keyword.get(opts, :precision),
      scale: Keyword.get(opts, :scale)
    }
  end

  describe "type names" do
    test "base_type_name/1 strips any (p,s) suffix" do
      assert Values.base_type_name("NUMBER(38,0)") == "NUMBER"
      assert Values.base_type_name(" varchar (16) ") == "VARCHAR"
      assert Values.base_type_name(nil) == ""
    end

    test "temporal_kind/1 names the shape" do
      assert Values.temporal_kind("DATE") == :date
      assert Values.temporal_kind("TIME") == :time
      assert Values.temporal_kind("TIMESTAMP_NTZ") == :naive
      assert Values.temporal_kind("DATETIME") == :naive
      assert Values.temporal_kind("TIMESTAMP_TZ") == :zoned
      assert Values.temporal_kind("TIMESTAMP_LTZ") == :zoned
      assert Values.temporal_kind("VARCHAR") == :none
    end

    test "declared_scale/1 prefers the wire's own field" do
      assert Values.declared_scale(column("NUMBER", scale: 4)) == 4
      assert Values.declared_scale(column("NUMBER(10,2)")) == 2
      assert Values.declared_scale(column("NUMBER", scale: 0)) == 0
      assert Values.declared_scale(column("VARCHAR")) == 0
    end

    test "integral_column?/1 reads scale, not the word" do
      assert Values.integral_column?(column("NUMBER", precision: 38, scale: 0))
      assert Values.integral_column?(column("INTEGER"))
      refute Values.integral_column?(column("NUMBER", precision: 10, scale: 2))
      refute Values.integral_column?(column("FLOAT"))
      refute Values.integral_column?(column("VARCHAR"))
    end
  end

  describe "convert_cell/2" do
    test "passes NULL and the VARIANT undefined sentinel through as nil" do
      assert Values.convert_cell(nil, column("VARCHAR")) == nil
      assert Values.convert_cell(:undefined, column("VARIANT")) == nil
    end

    test "keeps an integral column exact and a float column floating" do
      assert Values.convert_cell(3, column("NUMBER", precision: 38, scale: 0)) == 3
      assert Values.convert_cell(3, column("FLOAT")) == 3.0
      assert Values.convert_cell(2.5, column("NUMBER", precision: 10, scale: 1)) == 2.5

      big = 123_456_789_012_345_678_901_234_567_890
      assert Values.convert_cell(big, column("NUMBER", precision: 38, scale: 0)) == big
    end

    test "reports a float that is not a number as the atom Elixir has no float for" do
      assert Values.convert_cell(:nan, column("FLOAT")) == :nan
      assert Values.convert_cell(:infinity, column("FLOAT")) == :infinity
      assert Values.convert_cell(:neg_infinity, column("FLOAT")) == :neg_infinity
      # The engine actually sends them as JSON strings, even on a DOUBLE column.
      assert Values.convert_cell("NaN", column("FLOAT")) == :nan
      assert Values.convert_cell("Infinity", column("DOUBLE")) == :infinity
      assert Values.convert_cell("-Infinity", column("REAL")) == :neg_infinity
      # On a text column the words are just words.
      assert Values.convert_cell("NaN", column("VARCHAR")) == "NaN"
    end

    test "reads a whole number however the engine spelled it" do
      integral = column("NUMBER", precision: 38, scale: 0)
      assert Values.convert_cell(JSON.decode!("1E+3"), integral) == 1000
      assert Values.convert_cell(JSON.decode!("12.000"), integral) == 12
      assert Values.convert_cell(JSON.decode!("-1.5E+1"), integral) == -15
      assert Values.convert_cell(JSON.decode!("12345678901234567890123.00"), integral) ==
               12_345_678_901_234_567_890_123
      assert Values.convert_cell(JSON.decode!("1.25E+1"), integral) == 12.5
    end

    test "reads a DATE as a Date" do
      assert Values.convert_cell("2026-08-24", column("DATE")) == ~D[2026-08-24]
    end

    test "reads a TIME as a Time" do
      assert Values.convert_cell("10:20:30", column("TIME")) == ~T[10:20:30]
      assert Values.convert_cell("10:20:30.123456", column("TIME")) == ~T[10:20:30.123456]
    end

    test "reads a naive timestamp with no zone attached to it" do
      assert Values.convert_cell("2026-08-24 10:20:30.500", column("TIMESTAMP_NTZ")) ==
               ~N[2026-08-24 10:20:30.500]

      assert Values.convert_cell("2026-08-24T10:20:30", column("TIMESTAMP")) ==
               ~N[2026-08-24 10:20:30]
    end

    test "reads a zoned timestamp as the instant it names, in UTC" do
      assert Values.convert_cell("2026-08-24 12:20:30.500+02:00", column("TIMESTAMP_TZ")) ==
               ~U[2026-08-24 10:20:30.500Z]

      assert Values.convert_cell("2026-08-24 10:20:30Z", column("TIMESTAMP_LTZ")) ==
               ~U[2026-08-24 10:20:30Z]

      assert Values.convert_cell("2026-08-24 10:20:30-0130", column("TIMESTAMP_TZ")) ==
               ~U[2026-08-24 11:50:30Z]
    end

    test "a zoned timestamp with no offset at all still reads" do
      assert Values.convert_cell("2026-08-24 10:20:30", column("TIMESTAMP_TZ")) ==
               ~N[2026-08-24 10:20:30]
    end

    test "text that does not parse as a temporal is handed back untouched" do
      assert Values.convert_cell("not a date", column("DATE")) == "not a date"
      assert Values.convert_cell("2026-02-30", column("DATE")) == "2026-02-30"
    end

    test "reads BINARY as the bytes behind the hex" do
      assert Values.convert_cell("0A1B", column("BINARY")) == <<0x0A, 0x1B>>
      assert Values.convert_cell("", column("BINARY")) == ""
      assert Values.convert_cell("nothex", column("BINARY")) == "nothex"
      assert Values.convert_cell("ABC", column("BINARY")) == "ABC"
    end

    test "leaves text and booleans alone" do
      assert Values.convert_cell("hello", column("VARCHAR")) == "hello"
      assert Values.convert_cell(true, column("BOOLEAN")) == true
      assert Values.convert_cell(~s({"a":1}), column("VARIANT")) == ~s({"a":1})
    end

    test "renders a structural cell as its JSON text" do
      assert Values.convert_cell([1, :undefined], column("ARRAY")) == "[1,undefined]"
      assert Values.convert_cell(%{"a" => 1}, column("OBJECT")) == ~s({"a":1})
    end
  end

  describe "Result" do
    test "keys rows by column name on demand and keeps the positional view" do
      result = %Result{
        columns: [column("NUMBER", name: "ID"), column("VARCHAR", name: "NAME")],
        rows: [[1, "Ada"], [2, "Grace"]],
        num_rows: 2
      }

      assert Result.column_names(result) == ["ID", "NAME"]

      assert Result.to_maps(result) == [
               %{"ID" => 1, "NAME" => "Ada"},
               %{"ID" => 2, "NAME" => "Grace"}
             ]

      assert Result.value(result) == 1
      refute Result.update?(result)
    end

    test "value/1 answers nil for an empty grid" do
      assert Result.value(%Result{}) == nil
      assert Result.value(%Result{rows: [[]]}) == nil
    end

    test "update?/1 tells a DML answer from a query" do
      assert Result.update?(%Result{update_count: 0})
      refute Result.update?(%Result{update_count: -1})
    end
  end
end
