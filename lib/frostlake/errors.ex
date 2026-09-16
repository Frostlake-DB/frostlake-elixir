defmodule Frostlake.QueryError do
  @moduledoc """
  The engine refused a statement.

  `:message` is the engine's own wording, unmodified.

  `:statement` holds the SQL as it was sent — which, because binding happens
  client-side, means every parameter inlined. A bound password or card number
  appears in it verbatim, so log `Exception.message/1` freely and treat
  `:statement` as sensitive.
  """

  defexception [:message, :statement, :status]

  @type t :: %__MODULE__{
          message: String.t(),
          statement: String.t() | nil,
          status: pos_integer() | nil
        }
end

defmodule Frostlake.ConnectionError do
  @moduledoc """
  The request never became an answer.

  The host refused the socket, the connection died mid-statement, the deadline
  passed, or something that is not a Frostlake server answered.

  A statement that failed this way has an **unknown** fate: it may have run.
  Re-running it blindly would duplicate an `INSERT`.
  """

  defexception [:message, :endpoint, :status, :reason]

  @type t :: %__MODULE__{
          message: String.t(),
          endpoint: String.t() | nil,
          status: pos_integer() | nil,
          reason: term()
        }
end

defmodule Frostlake.UsageError do
  @moduledoc """
  The driver never sent it.

  A malformed DSN, a closed connection, a bind value with no SQL equivalent, an
  argument count that does not match the placeholders: the statement never
  reached the wire, so nothing happened server-side.
  """

  defexception [:message]

  @type t :: %__MODULE__{message: String.t()}
end
