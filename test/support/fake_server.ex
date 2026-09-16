defmodule Frostlake.FakeServer do
  @moduledoc """
  A scriptable HTTP server for the transport tests.

  It exists to produce the answers a real engine never should: a proxy's error
  page, a socket closed between statements, a reply that never comes. Everything
  else about the driver is tested against the engine itself.

  The handler is called with the request and the 1-based number of requests this
  server has seen, and returns what to do about it:

    * `{:reply, status, body}` — answer, with `Content-Length`, keeping the
      socket alive
    * `{:reply_chunked, status, body}` — answer in `Transfer-Encoding: chunked`
    * `{:reply_and_close, status, body}` — answer, then close
    * `:close` — close without answering
    * `:half_answer` — send a status line and close mid-response
    * `:hang` — leave the request unanswered
  """

  use GenServer

  @type request :: %{method: String.t(), path: String.t(), headers: map(), body: binary()}

  @spec start_link((request(), pos_integer() -> term())) :: {:ok, pid()}
  def start_link(handler) when is_function(handler, 2) do
    GenServer.start_link(__MODULE__, handler)
  end

  @doc "A DSN pointing at this server."
  @spec dsn(pid()) :: String.t()
  def dsn(server), do: "frostlake://127.0.0.1:#{port(server)}"

  @spec port(pid()) :: :inet.port_number()
  def port(server), do: GenServer.call(server, :port)

  @doc "Every request the server has seen, in order."
  @spec requests(pid()) :: [request()]
  def requests(server), do: GenServer.call(server, :requests)

  @spec stop(pid()) :: :ok
  def stop(server) do
    GenServer.stop(server, :normal)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(handler) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true, backlog: 16])

    {:ok, port} = :inet.port(listen)
    owner = self()
    acceptor = spawn_link(fn -> accept_loop(listen, owner, handler) end)
    {:ok, %{listen: listen, port: port, acceptor: acceptor, requests: []}}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}
  def handle_call(:requests, _from, state), do: {:reply, Enum.reverse(state.requests), state}

  @impl true
  def handle_call({:seen, request}, _from, state) do
    requests = [request | state.requests]
    {:reply, length(requests), %{state | requests: requests}}
  end

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listen)
    :ok
  end

  defp accept_loop(listen, owner, handler) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        spawn_link(fn -> serve(socket, owner, handler) end)
        accept_loop(listen, owner, handler)

      {:error, _reason} ->
        :ok
    end
  end

  defp serve(socket, owner, handler) do
    case read_request(socket) do
      {:ok, request} ->
        index = GenServer.call(owner, {:seen, request})

        case handler.(request, index) do
          {:reply, status, body} ->
            send_response(socket, status, body, close: false)
            serve(socket, owner, handler)

          {:reply_and_close, status, body} ->
            send_response(socket, status, body, close: true)
            :gen_tcp.close(socket)

          # Answers as though the socket were staying, then drops it anyway —
          # what the engine's own idle sweep looks like from a client.
          {:reply_then_drop, status, body} ->
            send_response(socket, status, body, close: false)
            :gen_tcp.close(socket)

          {:reply_chunked, status, body} ->
            send_chunked(socket, status, body)
            serve(socket, owner, handler)

          :close ->
            :gen_tcp.close(socket)

          :half_answer ->
            :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n{\"suc")
            :gen_tcp.close(socket)

          :hang ->
            Process.sleep(:infinity)
        end

      {:error, _reason} ->
        :gen_tcp.close(socket)
    end
  end

  defp read_request(socket) do
    :inet.setopts(socket, packet: :http_bin)

    with {:ok, {:http_request, method, {:abs_path, path}, _version}} <-
           :gen_tcp.recv(socket, 0, 30_000),
         {:ok, headers} <- read_headers(socket, %{}),
         :ok <- :inet.setopts(socket, packet: :raw),
         {:ok, body} <- read_body(socket, headers) do
      {:ok, %{method: to_string(method), path: path, headers: headers, body: body}}
    end
  end

  defp read_headers(socket, acc) do
    case :gen_tcp.recv(socket, 0, 30_000) do
      {:ok, :http_eoh} ->
        {:ok, acc}

      {:ok, {:http_header, _length, field, _reserved, value}} ->
        read_headers(socket, Map.put(acc, field |> to_string() |> String.downcase(), value))

      other ->
        other
    end
  end

  defp read_body(socket, headers) do
    case Integer.parse(Map.get(headers, "content-length", "0")) do
      {0, _} -> {:ok, ""}
      {size, _} -> :gen_tcp.recv(socket, size, 30_000)
      :error -> {:ok, ""}
    end
  end

  defp send_response(socket, status, body, opts) do
    connection = if opts[:close], do: "close", else: "keep-alive"

    :gen_tcp.send(socket, [
      "HTTP/1.1 ",
      Integer.to_string(status),
      " OK\r\nContent-Type: application/json\r\nContent-Length: ",
      Integer.to_string(byte_size(body)),
      "\r\nConnection: ",
      connection,
      "\r\n\r\n",
      body
    ])
  end

  defp send_chunked(socket, status, body) do
    <<head::binary-size(3), tail::binary>> = body

    :gen_tcp.send(socket, [
      "HTTP/1.1 ",
      Integer.to_string(status),
      " OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n",
      chunk(head),
      chunk(tail),
      "0\r\n\r\n"
    ])
  end

  defp chunk(data) do
    [data |> byte_size() |> Integer.to_string(16), "\r\n", data, "\r\n"]
  end
end
