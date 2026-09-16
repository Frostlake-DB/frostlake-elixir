defmodule Frostlake.Column do
  @moduledoc "What the engine reported about one column of a result set."

  defstruct [:name, :data_type, :nullable, :precision, :scale]

  @type t :: %__MODULE__{
          # The column's name, as the engine cased it.
          name: String.t(),
          # The declared SQL type, e.g. "NUMBER", "VARCHAR", "TIMESTAMP_NTZ".
          data_type: String.t(),
          # Whether the column admits NULL, or nil when the server did not say —
          # engines that predate the field report nothing rather than false.
          nullable: boolean() | nil,
          # Decimal precision and scale, for the fixed-point numeric types.
          precision: integer() | nil,
          scale: integer() | nil
        }
end

defmodule Frostlake.Result do
  @moduledoc """
  One result set: what a single statement answered with.

  `rows` is a list of lists, positionally aligned with `columns` — the shape the
  wire actually delivered, and the lossless one: a self-join reports `ID` twice
  and a map cannot hold both. `to_maps/1` is there when keys are what you want.
  """

  alias Frostlake.Column

  defstruct columns: [], rows: [], num_rows: 0, update_count: -1, counters: %{}

  @type t :: %__MODULE__{
          # The columns of the grid, in order.
          #
          # A DML statement answers with a status grid rather than data — one row
          # of `number of rows inserted`-style counters — and that grid is
          # reported here as it arrived. `update_count` is the friendly reading.
          columns: [Column.t()],
          rows: [[term()]],
          # Rows returned, or rows affected for a DML statement.
          num_rows: non_neg_integer(),
          # Rows affected by a DML statement, or -1 when the statement returned
          # data instead.
          #
          # The protocol carries no out-of-band count, so this is derived from
          # the status grid Frostlake and Snowflake both answer DML with.
          update_count: integer(),
          # The raw counters behind `update_count`, keyed by the engine's own
          # wording. A MERGE reports an inserted and an updated count
          # separately; `update_count` adds them up, and this is where the split
          # survives.
          counters: %{String.t() => integer()}
        }

  @doc """
  Each row as a map keyed by column name, built on demand.

  A map cannot represent two columns called the same thing — a self-join reports
  `ID` twice and the later one wins — so `rows` stays the lossless view.
  """
  @spec to_maps(t()) :: [%{String.t() => term()}]
  def to_maps(%__MODULE__{} = result) do
    names = column_names(result)
    Enum.map(result.rows, fn row -> names |> Enum.zip(row) |> Map.new() end)
  end

  @doc "The column names, in order."
  @spec column_names(t()) :: [String.t()]
  def column_names(%__MODULE__{columns: columns}), do: Enum.map(columns, & &1.name)

  @doc """
  The first cell of the first row, or `nil` when there is none.

  What a single-value query — `SELECT COUNT(*)`, `SELECT CURRENT_VERSION()` — is
  actually after.
  """
  @spec value(t()) :: term()
  def value(%__MODULE__{rows: [[first | _] | _]}), do: first
  def value(%__MODULE__{}), do: nil

  @doc "Whether this result came from a DML statement rather than a query."
  @spec update?(t()) :: boolean()
  def update?(%__MODULE__{update_count: count}), do: count >= 0
end
