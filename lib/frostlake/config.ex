defmodule Frostlake.Config do
  @moduledoc """
  A parsed DSN: everything a connection needs to reach a server and put a
  session on the right scope.

  Built by `Frostlake.DSN.parse/2`; every field can also be given to
  `Frostlake.connect/2` directly, where an explicit option outranks the DSN.
  """

  alias Frostlake.UsageError

  @default_port 18_082
  @default_connect_timeout 10_000
  @default_timeout 300_000
  @default_idle_limit 1_800_000

  defstruct host: "localhost",
            port: @default_port,
            secure: false,
            database: nil,
            schema: nil,
            role: nil,
            warehouse: nil,
            connect_timeout: @default_connect_timeout,
            timeout: @default_timeout,
            idle_limit: @default_idle_limit,
            verify_certificate: true,
            cacerts: nil,
            cacertfile: nil

  @type t :: %__MODULE__{
          host: String.t(),
          port: 1..65_535,
          secure: boolean(),
          database: String.t() | nil,
          schema: String.t() | nil,
          role: String.t() | nil,
          warehouse: String.t() | nil,
          connect_timeout: timeout(),
          timeout: non_neg_integer(),
          idle_limit: non_neg_integer(),
          verify_certificate: boolean(),
          cacerts: [binary()] | nil,
          cacertfile: Path.t() | nil
        }

  @doc "The port a `DatabaseHttpServer` listens on unless told otherwise."
  def default_port, do: @default_port

  @doc "Long enough for a slow query, short enough that an unreachable host fails while someone is watching."
  def default_connect_timeout, do: @default_connect_timeout
  def default_timeout, do: @default_timeout

  @doc """
  The engine reclaims a session after 30 minutes idle. Past that the driver has
  to assume its own is gone, because nothing in a response says so.
  """
  def default_idle_limit, do: @default_idle_limit

  @doc "The base URL of the server, without a trailing slash."
  @spec base_url(t()) :: String.t()
  def base_url(%__MODULE__{} = config) do
    scheme = if config.secure, do: "https", else: "http"
    "#{scheme}://#{host_for_url(config.host)}:#{config.port}"
  end

  @doc """
  The value of the `Host:` header — an IPv6 literal wears its brackets there.
  """
  @spec host_header(t()) :: String.t()
  def host_header(%__MODULE__{} = config), do: "#{host_for_url(config.host)}:#{config.port}"

  defp host_for_url(host) do
    if String.contains?(host, ":"), do: "[#{host}]", else: host
  end

  @doc """
  The DSN's scope rendered as the `USE` statements a fresh session needs, in
  dependency order.

  Rebuilt on demand, so a session that may have lapsed can be put back on this
  scope.
  """
  @spec use_statements(t()) :: [String.t()]
  def use_statements(%__MODULE__{} = config) do
    [
      config.role && "USE ROLE #{scope_identifier(config.role)}",
      config.warehouse && "USE WAREHOUSE #{scope_identifier(config.warehouse)}",
      config.database && "USE DATABASE #{scope_identifier(config.database)}",
      config.schema && "USE SCHEMA #{scope_identifier(config.schema)}"
    ]
    |> Enum.reject(&is_nil/1)
  end

  @plain_identifier ~r/\A[A-Za-z_][A-Za-z0-9_$]*\z/

  @doc """
  Renders a name the DSN gives for a `USE` statement.

  A plain name — one that could stand unquoted in SQL — means what it means
  there: the upper-case object it folds to, so `my_db` selects `MY_DB`. A name
  already wrapped in double quotes keeps its exact case, the way the Snowflake
  connectors read one. Anything else is quoted exactly as given.

  The engine resolves a quoted name exactly, as Snowflake does, so quoting a
  plain name without folding it would ask for a lower-case object that is
  almost never there.
  """
  @spec scope_identifier(String.t()) :: String.t()
  def scope_identifier(name) when is_binary(name) do
    cond do
      Regex.match?(@plain_identifier, name) ->
        quote_identifier(String.upcase(name))

      byte_size(name) >= 2 and String.starts_with?(name, ~s(")) and
          String.ends_with?(name, ~s(")) ->
        name
        |> binary_part(1, byte_size(name) - 2)
        |> String.replace(~s(""), ~s("))
        |> quote_identifier()

      true ->
        quote_identifier(name)
    end
  end

  @doc """
  Quotes an identifier for use in a statement, keeping its case.

  Always quoted. Leaving "unambiguous" names bare lets through ones that cannot
  legally appear that way — `1ABC` starts with a digit, `SELECT` is reserved —
  and quoting an upper-case name costs nothing: `"NAME"` and `NAME` name the
  same object. Embedded quotes are doubled, so a name arriving from a DSN
  cannot break out.
  """
  @spec quote_identifier(String.t()) :: String.t()
  def quote_identifier(""), do: raise(UsageError, message: "an identifier cannot be empty")

  def quote_identifier(name) when is_binary(name) do
    ~s("#{String.replace(name, ~s("), ~s(""))}")
  end
end
