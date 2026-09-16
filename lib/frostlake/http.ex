defmodule Frostlake.HTTP do
  @moduledoc """
  The driver's HTTP/1.1 transport: one socket, kept alive between statements.

  It is hand-rolled rather than borrowed for one reason above the others. A
  general-purpose client re-sends a request whose persistent connection turned
  out to be dead, and a re-sent `INSERT` inserts twice. Here a statement that
  reached the wire is never sent again: the only recovery is for a **reused**
  socket whose write failed outright, where nothing was transmitted at all. A
  socket the server closed while it sat idle — which the engine's own HTTP
  server does — is spotted by `alive?/1` before a request is written to it.
  """

  alias Frostlake.Config

  @type socket :: {:tcp, :gen_tcp.socket()} | {:ssl, :ssl.sslsocket()}
  @type deadline :: integer() | :infinity

  @user_agent "frostlake-elixir/0.1.0"

  @doc "Opens a socket to the server the config names."
  @spec connect(Config.t()) :: {:ok, socket()} | {:error, term()}
  def connect(%Config{} = config) do
    address = String.to_charlist(config.host)
    timeout = if config.connect_timeout == 0, do: :infinity, else: config.connect_timeout

    options =
      [:binary, active: false, packet: :raw, nodelay: true, keepalive: true] ++
        family(config.host)

    if config.secure do
      with {:ok, _started} <- Application.ensure_all_started(:ssl),
           {:ok, tls} <- tls_options(config),
           {:ok, socket} <- :ssl.connect(address, config.port, options ++ tls, timeout) do
        {:ok, {:ssl, socket}}
      end
    else
      case :gen_tcp.connect(address, config.port, options, timeout) do
        {:ok, socket} -> {:ok, {:tcp, socket}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp family(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} when tuple_size(address) == 8 -> [:inet6]
      _ -> []
    end
  end

  defp tls_options(%Config{verify_certificate: false}), do: {:ok, [verify: :verify_none]}

  defp tls_options(%Config{} = config) do
    with {:ok, trust} <- trust_store(config) do
      {:ok,
       trust ++
         [
           verify: :verify_peer,
           depth: 4,
           server_name_indication: String.to_charlist(config.host),
           customize_hostname_check: [
             match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
           ]
         ]}
    end
  end

  defp trust_store(%Config{cacerts: cacerts}) when is_list(cacerts), do: {:ok, [cacerts: cacerts]}

  defp trust_store(%Config{cacertfile: file}) when is_binary(file) do
    {:ok, [cacertfile: String.to_charlist(file)]}
  end

  defp trust_store(_config) do
    # The OS trust store, when this OTP build can find one. Falling back to
    # verify_none instead would turn a configuration problem into a silent
    # downgrade, so say so and let the caller decide.
    {:ok, [cacerts: :public_key.cacerts_get()]}
  rescue
    _ -> {:error, :no_trusted_certificates}
  catch
    _, _ -> {:error, :no_trusted_certificates}
  end

  @doc """
  Sends one request and reads its response.

  Returns `{:ok, status, headers, body}`, or `{:error, reason, phase}` where
  `phase` is `:not_sent` when the write itself failed and nothing reached the
  server — the one state from which re-sending is safe — and `:sent` once the
  request is on the wire, whatever became of the answer.
  """
  @spec request(socket(), String.t(), String.t(), String.t(), iodata() | nil, deadline()) ::
          {:ok, pos_integer(), [{String.t(), binary()}], binary()}
          | {:error, term(), :not_sent | :sent}
  def request(socket, method, path, host, body, deadline) do
    case send_data(socket, [request_line(method, path, host, body), body || []]) do
      :ok -> read_response(socket, deadline)
      {:error, reason} -> {:error, reason, :not_sent}
    end
  end

  defp request_line(method, path, host, body) do
    [
      method,
      " ",
      path,
      " HTTP/1.1\r\nHost: ",
      host,
      "\r\nUser-Agent: ",
      @user_agent,
      "\r\nAccept: application/json\r\nConnection: keep-alive\r\n",
      if(body,
        do: [
          "Content-Type: application/json\r\nContent-Length: ",
          Integer.to_string(IO.iodata_length(body)),
          "\r\n"
        ],
        else: []
      ),
      "\r\n"
    ]
  end

  defp read_response(socket, deadline) do
    # The BEAM's own HTTP packet mode parses the status line and headers, so the
    # driver is not carrying a second implementation of them.
    with :ok <- setopts(socket, packet: :http_bin),
         {:ok, status} <- read_status(socket, deadline),
         {:ok, headers} <- read_headers(socket, deadline, []),
         :ok <- setopts(socket, packet: :raw),
         {:ok, body} <- read_body(socket, headers, deadline) do
      {:ok, status, headers, body}
    else
      {:error, reason} -> {:error, reason, :sent}
    end
  end

  defp read_status(socket, deadline) do
    case recv(socket, 0, remaining(deadline)) do
      {:ok, {:http_response, _version, status, _phrase}} -> {:ok, status}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_headers(socket, deadline, acc) do
    case recv(socket, 0, remaining(deadline)) do
      {:ok, :http_eoh} ->
        {:ok, Enum.reverse(acc)}

      {:ok, {:http_header, _length, field, _reserved, value}} ->
        name = field |> to_string() |> String.downcase()
        read_headers(socket, deadline, [{name, value} | acc])

      {:ok, other} ->
        {:error, {:unexpected_header, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_body(socket, headers, deadline) do
    cond do
      chunked?(headers) ->
        read_chunked(socket, deadline, [])

      size = content_length(headers) ->
        if size == 0, do: {:ok, ""}, else: recv(socket, size, remaining(deadline))

      true ->
        # Neither framing header: the body runs to the close of the connection.
        read_until_closed(socket, deadline, [])
    end
  end

  defp read_chunked(socket, deadline, acc) do
    with :ok <- setopts(socket, packet: :line),
         {:ok, line} <- recv(socket, 0, remaining(deadline)),
         {:ok, size} <- chunk_size(line),
         :ok <- setopts(socket, packet: :raw) do
      if size == 0 do
        with :ok <- skip_trailers(socket, deadline) do
          {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
        end
      else
        # The chunk carries a trailing CRLF of its own.
        case recv(socket, size + 2, remaining(deadline)) do
          {:ok, chunk} -> read_chunked(socket, deadline, [binary_part(chunk, 0, size) | acc])
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  defp chunk_size(line) do
    case line |> String.trim() |> String.split(";", parts: 2) |> hd() |> Integer.parse(16) do
      {size, ""} when size >= 0 -> {:ok, size}
      _ -> {:error, {:invalid_chunk_size, line}}
    end
  end

  defp skip_trailers(socket, deadline) do
    with :ok <- setopts(socket, packet: :line),
         {:ok, line} <- recv(socket, 0, remaining(deadline)) do
      if String.trim(line) == "" do
        setopts(socket, packet: :raw)
      else
        skip_trailers(socket, deadline)
      end
    end
  end

  defp read_until_closed(socket, deadline, acc) do
    case recv(socket, 0, remaining(deadline)) do
      {:ok, data} -> read_until_closed(socket, deadline, [data | acc])
      {:error, :closed} -> {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp chunked?(headers) do
    case List.keyfind(headers, "transfer-encoding", 0) do
      {_, value} -> value |> String.downcase() |> String.contains?("chunked")
      nil -> false
    end
  end

  defp content_length(headers) do
    with {_, value} <- List.keyfind(headers, "content-length", 0),
         {length, ""} <- value |> String.trim() |> Integer.parse() do
      length
    else
      _ -> nil
    end
  end

  @doc """
  Whether the answer allows this socket to serve another request.
  """
  @spec keep_alive?([{String.t(), binary()}]) :: boolean()
  def keep_alive?(headers) do
    case List.keyfind(headers, "connection", 0) do
      {_, value} -> not (value |> String.downcase() |> String.contains?("close"))
      nil -> content_length(headers) != nil or chunked?(headers)
    end
  end

  @doc """
  Whether a socket kept from an earlier statement is still usable.

  The engine's HTTP server closes a connection it has held idle, and unread
  bytes mean the two sides disagree about where the last response ended; either
  way the socket is finished.
  """
  @spec alive?(socket()) :: boolean()
  def alive?(socket) do
    case recv(socket, 0, 0) do
      {:error, :timeout} -> true
      _ -> false
    end
  end

  @doc "Closes a socket, ignoring the state it was in."
  @spec close(socket() | nil) :: :ok
  def close(nil), do: :ok
  def close({:tcp, socket}), do: :gen_tcp.close(socket)

  def close({:ssl, socket}) do
    _ = :ssl.close(socket)
    :ok
  end

  @doc "A deadline `timeout` milliseconds from now; `0` means no deadline at all."
  @spec deadline(non_neg_integer()) :: deadline()
  def deadline(0), do: :infinity
  def deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp remaining(:infinity), do: :infinity

  defp remaining(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  defp send_data({:tcp, socket}, data), do: :gen_tcp.send(socket, data)
  defp send_data({:ssl, socket}, data), do: :ssl.send(socket, data)

  defp recv({:tcp, socket}, length, timeout), do: :gen_tcp.recv(socket, length, timeout)
  defp recv({:ssl, socket}, length, timeout), do: :ssl.recv(socket, length, timeout)

  defp setopts({:tcp, socket}, options), do: :inet.setopts(socket, options)
  defp setopts({:ssl, socket}, options), do: :ssl.setopts(socket, options)
end
