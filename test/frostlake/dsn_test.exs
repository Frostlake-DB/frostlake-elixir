defmodule Frostlake.DSNTest do
  use ExUnit.Case, async: true

  alias Frostlake.{Config, DSN}

  doctest Frostlake.DSN

  describe "parse/2" do
    test "reads host, port, database and the engine's default port" do
      assert {:ok, config} = DSN.parse("frostlake://db.example:1234/SALES")
      assert config.host == "db.example"
      assert config.port == 1234
      assert config.database == "SALES"
      refute config.secure

      assert {:ok, %Config{port: 18_082}} = DSN.parse("frostlake://localhost")
    end

    test "http and https mean the same thing, with their own default ports" do
      assert {:ok, %Config{port: 80, secure: false}} = DSN.parse("http://localhost")
      assert {:ok, %Config{port: 443, secure: true}} = DSN.parse("https://localhost")
      assert {:ok, %Config{port: 8443, secure: true}} = DSN.parse("https://localhost:8443")
    end

    test "tls=true upgrades a frostlake:// DSN" do
      assert {:ok, %Config{secure: true}} = DSN.parse("frostlake://localhost?tls=true")
      assert {:ok, %Config{secure: false}} = DSN.parse("frostlake://localhost?tls=no")
    end

    test "reads the scope parameters" do
      dsn = "frostlake://localhost/DB?schema=PUBLIC&role=SYSADMIN&warehouse=WH"
      assert {:ok, config} = DSN.parse(dsn)
      assert config.schema == "PUBLIC"
      assert config.role == "SYSADMIN"
      assert config.warehouse == "WH"
    end

    test "reads durations in either spelling" do
      assert {:ok, config} =
               DSN.parse("frostlake://h?timeout=90s&connectTimeout=500ms&idleLimit=2m")

      assert config.timeout == 90_000
      assert config.connect_timeout == 500
      assert config.idle_limit == 120_000

      assert {:ok, %Config{connect_timeout: 250}} =
               DSN.parse("frostlake://h?connect_timeout=250ms")

      assert {:ok, %Config{timeout: 45_000}} = DSN.parse("frostlake://h?timeout=45")
      assert {:ok, %Config{timeout: 0}} = DSN.parse("frostlake://h?timeout=0")
      assert {:ok, %Config{timeout: 3_600_000}} = DSN.parse("frostlake://h?timeout=1h")
    end

    test "keeps the defaults when nothing says otherwise" do
      assert {:ok, config} = DSN.parse("frostlake://h")
      assert config.timeout == Config.default_timeout()
      assert config.connect_timeout == Config.default_connect_timeout()
      assert config.idle_limit == Config.default_idle_limit()
    end

    test "an unknown parameter is a typo, not a no-op" do
      assert {:error, error} = DSN.parse("frostlake://h?schmea=PUBLIC")
      assert error.message =~ "unknown DSN parameter: schmea"
      assert error.message =~ "expected connectTimeout"
    end

    test "credentials are refused rather than dropped" do
      assert {:error, error} = DSN.parse("frostlake://user:secret@localhost")
      assert error.message =~ "takes no credentials"
    end

    test "rejects a scheme it does not speak" do
      assert {:error, error} = DSN.parse("postgres://localhost")
      assert error.message =~ "must start with frostlake://"
    end

    test "rejects a missing host, a bad port and a two-segment path" do
      assert {:error, _} = DSN.parse("frostlake:///DB")
      assert {:error, error} = DSN.parse("frostlake://h:99999")
      assert error.message =~ "between 1 and 65535"
      assert {:error, error} = DSN.parse("frostlake://h/DB/extra")
      assert error.message =~ "names one database"
    end

    test "rejects a malformed duration and an empty scope parameter" do
      assert {:error, error} = DSN.parse("frostlake://h?timeout=soon")
      assert error.message =~ "must be a duration"
      assert {:error, error} = DSN.parse("frostlake://h?schema=")
      assert error.message =~ "cannot be empty"
    end

    test "a trailing slash is fine" do
      assert {:ok, %Config{database: nil}} = DSN.parse("frostlake://localhost/")
    end

    test "percent-encoding survives" do
      assert {:ok, config} = DSN.parse("frostlake://localhost/my%20db?schema=a%2Fb")
      assert config.database == "my db"
      assert config.schema == "a/b"
    end
  end

  describe "options" do
    test "outrank the DSN" do
      assert {:ok, config} =
               DSN.parse("frostlake://h/DB?schema=PUBLIC&timeout=10s",
                 schema: "OTHER",
                 timeout: 250
               )

      assert config.schema == "OTHER"
      assert config.timeout == 250
      assert config.database == "DB"
    end

    test "accept :infinity as no bound at all" do
      assert {:ok, %Config{timeout: 0}} = DSN.parse("frostlake://h", timeout: :infinity)
    end

    test "an unknown option is reported" do
      assert {:error, error} = DSN.parse("frostlake://h", schmea: "PUBLIC")
      assert error.message =~ "unknown option: :schmea"
    end

    test "reject a timeout that is not a duration" do
      assert {:error, error} = DSN.parse("frostlake://h", timeout: -1)
      assert error.message =~ "must be a duration"
    end
  end

  describe "use statements" do
    test "are rendered in dependency order, and only for what the DSN named" do
      assert {:ok, config} =
               DSN.parse("frostlake://h/DB?schema=PUBLIC&role=SYSADMIN&warehouse=WH")

      assert Config.use_statements(config) == [
               ~s(USE ROLE "SYSADMIN"),
               ~s(USE WAREHOUSE "WH"),
               ~s(USE DATABASE "DB"),
               ~s(USE SCHEMA "PUBLIC")
             ]

      assert {:ok, config} = DSN.parse("frostlake://h")
      assert Config.use_statements(config) == []
    end

    test "quote an identifier so a name from outside cannot break out" do
      assert {:ok, config} = DSN.parse("frostlake://h", database: ~s(a"; DROP DATABASE x; --))
      assert Config.use_statements(config) == [~s(USE DATABASE "a""; DROP DATABASE x; --")]

      assert {:ok, config} = DSN.parse("frostlake://h", database: ~s("a"; DROP DATABASE x; --"))
      assert Config.use_statements(config) == [~s(USE DATABASE "a""; DROP DATABASE x; --")]
    end

    test "fold a plain name to the upper-case object it means unquoted" do
      assert {:ok, config} =
               DSN.parse(
                 "frostlake://h/lower_case?schema=Mixed_Case&role=sysadmin&warehouse=wh$1"
               )

      assert Config.use_statements(config) == [
               ~s(USE ROLE "SYSADMIN"),
               ~s(USE WAREHOUSE "WH$1"),
               ~s(USE DATABASE "LOWER_CASE"),
               ~s(USE SCHEMA "MIXED_CASE")
             ]
    end

    test "keep the case of a name that is not plain, or that arrives quoted" do
      assert {:ok, config} = DSN.parse("frostlake://h/%22lower_case%22?schema=Mixed%20Case")

      assert Config.use_statements(config) == [
               ~s(USE DATABASE "lower_case"),
               ~s(USE SCHEMA "Mixed Case")
             ]

      assert Config.scope_identifier("1abc") == ~s("1abc")
      assert Config.scope_identifier(~s("say ""hi""")) == ~s("say ""hi""")
      assert Config.scope_identifier(~s(")) == ~s("""")
    end
  end

  describe "base_url/1 and host_header/1" do
    test "render the scheme, host and port" do
      assert {:ok, config} = DSN.parse("frostlake://localhost:1234/DB")
      assert Config.base_url(config) == "http://localhost:1234"
      assert Config.host_header(config) == "localhost:1234"

      assert {:ok, config} = DSN.parse("https://example.test/DB")
      assert Config.base_url(config) == "https://example.test:443"
    end

    test "an IPv6 literal wears its brackets in a URL and a Host header" do
      assert {:ok, config} = DSN.parse("frostlake://[::1]:18082/DB")
      assert config.host == "::1"
      assert Config.base_url(config) == "http://[::1]:18082"
      assert Config.host_header(config) == "[::1]:18082"
    end
  end
end
