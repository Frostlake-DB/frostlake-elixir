defmodule Frostlake.DSN do
  @moduledoc """
  Parsing of `frostlake://host[:port][/DATABASE][?param=value&…]` connection
  strings.

  `http://` and `https://` are accepted too and mean the same thing; the custom
  scheme exists so a DSN reads as a database URL rather than a web one.

      iex> {:ok, config} = Frostlake.DSN.parse("frostlake://localhost/MY_DB?schema=PUBLIC")
      iex> {config.host, config.port, config.database, config.schema}
      {"localhost", 18082, "MY_DB", "PUBLIC"}

  Every query parameter may be written in either the camelCase spelling the
  other Frostlake drivers use (`connectTimeout`) or the snake_case one Elixir
  reads more naturally (`connect_timeout`).
  """

  alias Frostlake.{Config, UsageError}

  @parameters %{
    "connecttimeout" => :connect_timeout,
    "idlelimit" => :idle_limit,
    "role" => :role,
    "schema" => :schema,
    "timeout" => :timeout,
    "tls" => :tls,
    "warehouse" => :warehouse
  }

  @canonical "connectTimeout, idleLimit, role, schema, timeout, tls, warehouse"

  @option_keys [
    :database,
    :schema,
    :role,
    :warehouse,
    :timeout,
    :connect_timeout,
    :idle_limit,
    :tls,
    :verify_certificate,
    :cacerts,
    :cacertfile
  ]

  @doc """
  Parses a DSN, with `opts` overriding whatever the DSN said.

  Returns `{:ok, %Frostlake.Config{}}` or `{:error, %Frostlake.UsageError{}}`.
  """
  @spec parse(String.t(), keyword()) :: {:ok, Config.t()} | {:error, UsageError.t()}
  def parse(dsn, opts \\ []) when is_binary(dsn) and is_list(opts) do
    {:ok, parse!(dsn, opts)}
  rescue
    error in UsageError -> {:error, error}
  end

  @doc "Same as `parse/2`, but raises `Frostlake.UsageError` instead of returning it."
  @spec parse!(String.t(), keyword()) :: Config.t()
  def parse!(dsn, opts \\ []) when is_binary(dsn) and is_list(opts) do
    uri = parse_uri(dsn)
    scheme = String.downcase(uri.scheme || "")

    unless scheme in ["frostlake", "http", "https"] do
      fail("a DSN must start with frostlake://, http:// or https://")
    end

    if uri.host in [nil, ""], do: fail("the DSN is missing host[:port]")

    # The server authenticates nobody, so credentials in a DSN would be silently
    # dropped — and silently dropping a password is worse than saying so.
    if uri.userinfo not in [nil, ""] do
      fail("the server takes no credentials; remove user:password from the DSN")
    end

    query = decode_query(uri)

    config = %Config{
      host: uri.host,
      port: port_of(uri, scheme),
      secure: scheme == "https" or Map.get(query, :tls, false),
      database: database_of(uri),
      schema: query[:schema],
      role: query[:role],
      warehouse: query[:warehouse],
      connect_timeout: query[:connect_timeout] || Config.default_connect_timeout(),
      timeout: query[:timeout] || Config.default_timeout(),
      idle_limit: query[:idle_limit] || Config.default_idle_limit()
    }

    apply_options(config, opts)
  end

  @doc """
  Applies explicit `Frostlake.connect/2` options on top of a config.

  An option always outranks the DSN, which is what lets a caller keep one DSN
  and vary a timeout per connection.
  """
  @spec apply_options(Config.t(), keyword()) :: Config.t()
  def apply_options(%Config{} = config, opts) do
    case Keyword.keys(opts) -- @option_keys do
      [] -> :ok
      unknown -> fail("unknown option: #{Enum.map_join(Enum.sort(unknown), ", ", &inspect/1)}")
    end

    Enum.reduce(opts, config, fn
      {:database, value}, acc ->
        %{acc | database: identifier(:database, value)}

      {:schema, value}, acc ->
        %{acc | schema: identifier(:schema, value)}

      {:role, value}, acc ->
        %{acc | role: identifier(:role, value)}

      {:warehouse, value}, acc ->
        %{acc | warehouse: identifier(:warehouse, value)}

      {:timeout, value}, acc ->
        %{acc | timeout: duration(:timeout, value)}

      {:connect_timeout, v}, acc ->
        %{acc | connect_timeout: duration(:connect_timeout, v)}

      {:idle_limit, value}, acc ->
        %{acc | idle_limit: duration(:idle_limit, value)}

      {:tls, value}, acc ->
        %{acc | secure: boolean(:tls, value)}

      {:verify_certificate, v}, acc ->
        %{acc | verify_certificate: boolean(:verify_certificate, v)}

      {:cacerts, value}, acc ->
        %{acc | cacerts: value}

      {:cacertfile, value}, acc ->
        %{acc | cacertfile: value}
    end)
  end

  defp parse_uri(dsn) do
    case URI.new(dsn) do
      {:ok, uri} -> uri
      {:error, part} -> fail(~s(invalid DSN "#{dsn}": unexpected "#{part}"))
    end
  end

  # URI fills in a default port for http and https only. Reading the engine's
  # own default into those would quietly move an https://h:443 DSN elsewhere, so
  # only the custom scheme — which has no default of its own — falls back to it.
  defp port_of(uri, scheme) do
    port = uri.port || if(scheme == "frostlake", do: Config.default_port())

    cond do
      is_nil(port) -> fail("the DSN is missing a port")
      port < 1 or port > 65_535 -> fail("the DSN port must be between 1 and 65535, got #{port}")
      true -> port
    end
  end

  # A trailing slash is fine; a second segment means the caller meant something
  # the DSN cannot express, and "db/extra" is not an identifier.
  defp database_of(uri) do
    case String.split(uri.path || "", "/", trim: true) do
      [] -> nil
      [database] -> URI.decode(database)
      _ -> fail(~s(the DSN path names one database, got "#{uri.path}"))
    end
  end

  defp decode_query(uri) do
    (uri.query || "")
    |> URI.decode_query()
    |> Enum.map(fn {key, value} -> {parameter(key), value} end)
    |> Enum.map(fn
      {name, value} when name in [:schema, :role, :warehouse] ->
        {name, identifier(name, value)}

      {name, value} when name in [:timeout, :connect_timeout, :idle_limit] ->
        {name, duration(name, value)}

      {:tls, value} ->
        {:tls, boolean(:tls, value)}
    end)
    |> Map.new()
  end

  # A typo is an error rather than a silent no-op: a misspelled `schema` or
  # `timeout` changes behaviour without saying so.
  defp parameter(key) do
    case Map.fetch(@parameters, key |> String.downcase() |> String.replace("_", "")) do
      {:ok, name} -> name
      :error -> fail("unknown DSN parameter: #{key} (expected #{@canonical})")
    end
  end

  defp identifier(name, value) when is_binary(value) do
    if value == "", do: fail("the DSN parameter #{name} cannot be empty"), else: value
  end

  defp identifier(name, value), do: fail("#{name} must be a string, got #{inspect(value)}")

  defp boolean(_name, value) when is_boolean(value), do: value

  defp boolean(name, value) when is_binary(value) do
    case String.downcase(value) do
      truthy when truthy in ["true", "1", "yes"] -> true
      falsy when falsy in ["false", "0", "no"] -> false
      _ -> fail(~s(#{name} must be true or false, got "#{value}"))
    end
  end

  defp boolean(name, value), do: fail("#{name} must be true or false, got #{inspect(value)}")

  # A duration is milliseconds as an integer — what every other Elixir API takes
  # — or the string spelling a connection string uses: a bare number of seconds,
  # or a number with a ms/s/m/h suffix. Zero is meaningful (it removes the
  # bound), so it is accepted where a negative number is not.
  defp duration(_name, :infinity), do: 0
  defp duration(_name, value) when is_integer(value) and value >= 0, do: value

  defp duration(name, value) when is_binary(value) do
    case Regex.run(~r/^(\d+(?:\.\d+)?)(ms|s|m|h)?$/, String.trim(value)) do
      [_, amount] -> scale(amount, "s")
      [_, amount, unit] -> scale(amount, unit)
      _ -> fail(~s(#{name} must be a duration such as 30s, 500ms or 5m, got "#{value}"))
    end
  end

  defp duration(name, value) do
    fail(
      "#{name} must be a duration in milliseconds or a string such as \"30s\", " <>
        "got #{inspect(value)}"
    )
  end

  defp scale(amount, unit) do
    factor =
      case unit do
        "ms" -> 1
        "s" -> 1_000
        "m" -> 60_000
        "h" -> 3_600_000
      end

    {number, ""} = Float.parse(amount)
    round(number * factor)
  end

  defp fail(message), do: raise(UsageError, message: message)
end
