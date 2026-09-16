defmodule Frostlake.SQLTest do
  use ExUnit.Case, async: true

  alias Frostlake.SQL

  describe "split_statements/1" do
    test "splits on top-level semicolons" do
      assert SQL.split_statements("SELECT 1; SELECT 2") == ["SELECT 1", " SELECT 2"]
      assert SQL.split_statements("SELECT 1") == ["SELECT 1"]
      assert SQL.split_statements("SELECT 1;") == ["SELECT 1", ""]
    end

    test "leaves alone a semicolon inside a literal, an identifier, a comment or a body" do
      assert SQL.split_statements("SELECT ';'") == ["SELECT ';'"]
      assert SQL.split_statements(~s(SELECT "a;b")) == [~s(SELECT "a;b")]
      assert SQL.split_statements("SELECT 1 -- ;\n") == ["SELECT 1 -- ;\n"]
      assert SQL.split_statements("SELECT 1 /* ; */") == ["SELECT 1 /* ; */"]

      assert SQL.split_statements("CREATE PROCEDURE p() AS $$ BEGIN; END; $$") ==
               ["CREATE PROCEDURE p() AS $$ BEGIN; END; $$"]
    end

    test "an unterminated region swallows the rest rather than looping" do
      assert SQL.split_statements("SELECT 'unterminated; SELECT 2") ==
               ["SELECT 'unterminated; SELECT 2"]
    end

    test "multi-byte text does not shift the offsets" do
      assert SQL.split_statements("SELECT 'zażółć'; SELECT 2") == ["SELECT 'zażółć'", " SELECT 2"]
    end
  end

  describe "changes_session_scope?/1" do
    test "flags what moves the session" do
      assert SQL.changes_session_scope?("USE SCHEMA other")
      assert SQL.changes_session_scope?("use database x")
      assert SQL.changes_session_scope?("SET v = 1")
      assert SQL.changes_session_scope?("UNSET v")
      assert SQL.changes_session_scope?("ALTER SESSION SET TIMEZONE = 'UTC'")
      assert SQL.changes_session_scope?("CREATE OR REPLACE DATABASE db")
      assert SQL.changes_session_scope?("DROP SCHEMA IF EXISTS s")
      assert SQL.changes_session_scope?("CREATE TRANSIENT SCHEMA s")
    end

    test "leaves alone what does not" do
      refute SQL.changes_session_scope?("SELECT 1")
      refute SQL.changes_session_scope?("CREATE TABLE t (id INT)")
      refute SQL.changes_session_scope?("CREATE OR REPLACE TABLE t (id INT)")
      refute SQL.changes_session_scope?("DROP TABLE IF EXISTS t")
      refute SQL.changes_session_scope?("ALTER TABLE t ADD COLUMN c INT")
      refute SQL.changes_session_scope?("INSERT INTO t VALUES (1)")
      refute SQL.changes_session_scope?("")
    end

    test "a USE riding behind another statement counts" do
      assert SQL.changes_session_scope?("SELECT 1; USE SCHEMA other")
    end

    test "a leading comment does not hide the verb" do
      assert SQL.changes_session_scope?("-- switch\nUSE SCHEMA other")
      assert SQL.changes_session_scope?("/* switch */ USE SCHEMA other")
    end

    test "a statement that only mentions the words does not count" do
      refute SQL.changes_session_scope?("SELECT 'USE SCHEMA x'")
      refute SQL.changes_session_scope?("SELECT use_count FROM t")
    end
  end

  describe "leading_words/2" do
    test "reads up to n upper-cased words" do
      assert SQL.leading_words("  create or replace table t", 3) == ["CREATE", "OR", "REPLACE"]
      assert SQL.leading_words("SELECT 1", 6) == ["SELECT", "1"]
      assert SQL.leading_words("", 6) == []
      assert SQL.leading_words("'literal' first", 6) == []
    end
  end
end
