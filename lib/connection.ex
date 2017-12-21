defmodule Kadabra.Connection do
  @moduledoc false

  defstruct ref: nil,
            buffer: "",
            client: nil,
            uri: nil,
            scheme: :https,
            opts: [],
            socket: nil,
            queue: nil,
            flow_control: nil

  use GenStage
  require Logger

  alias Kadabra.{Connection, ConnectionQueue, Encodable, Error, Frame,
    FrameParser, Hpack, Http2, Stream, StreamSupervisor}
  alias Kadabra.Connection.Ssl
  alias Kadabra.Frame.{Continuation, Data, Goaway, Headers, Ping,
    PushPromise, RstStream, WindowUpdate}

  @type t :: %__MODULE__{
    buffer: binary,
    client: pid,
    flow_control: term,
    opts: Keyword.t,
    ref: nil,
    scheme: :https,
    socket: sock,
    uri: charlist | String.t
  }

  @type sock :: {:sslsocket, any, pid | {any, any}}

  @type frame :: Data.t
               | Headers.t
               | RstStream.t
               | Frame.Settings.t
               | PushPromise.t
               | Ping.t
               | Goaway.t
               | WindowUpdate.t
               | Continuation.t

  def start_link(uri, pid, sup, ref, opts \\ []) do
    name = via_tuple(sup)
    GenStage.start_link(__MODULE__, {:ok, uri, pid, sup, ref, opts}, name: name)
  end

  def via_tuple(ref) do
    {:via, Registry, {Registry.Kadabra, {ref, __MODULE__}}}
  end

  def init({:ok, uri, pid, sup, ref, opts}) do
    case Ssl.connect(uri, opts) do
      {:ok, socket} ->
        send_preface_and_settings(socket, opts[:settings])
        state = initial_state(socket, uri, pid, ref, opts)
        {:consumer, state, subscribe_to: [ConnectionQueue.via_tuple(sup)]}
      {:error, error} ->
        Logger.error(inspect(error))
        {:error, error}
    end
  end

  defp initial_state(socket, uri, pid, ref, opts) do
   %__MODULE__{
      ref: ref,
      client: pid,
      uri: uri,
      scheme: Keyword.get(opts, :scheme, :https),
      opts: opts,
      socket: socket,
      flow_control: %Kadabra.Connection.FlowControl{
        settings: Keyword.get(opts, :settings, Connection.Settings.default)
      }
    }
  end

  defp send_preface_and_settings(socket, settings) do
    :ssl.send(socket, Http2.connection_preface)
    bin =
      %Frame.Settings{settings: settings || Connection.Settings.default}
      |> Encodable.to_bin
    :ssl.send(socket, bin)
  end

  # handle_cast

  def handle_cast({:recv, frame}, state) do
    recv(frame, state)
  end

  def handle_cast({:send, type}, state) do
    sendf(type, state)
  end

  def handle_cast(_msg, state) do
    {:noreply, [], state}
  end

  def handle_events(events, _from, state) do
    new_state = Enum.reduce(events, state, & do_send_headers(&1, &2))
    {:noreply, [], new_state}
  end

  def handle_subscribe(:producer, _opts, from, state) do
    {:manual, %{state | queue: from}}
  end

  # sendf

  @spec sendf(:goaway | :ping, t) :: {:noreply, [], t}
  def sendf(:ping, %Connection{socket: socket} = state) do
    bin = Ping.new |> Encodable.to_bin
    :ssl.send(socket, bin)
    {:noreply, [], state}
  end
  def sendf(:goaway, %Connection{socket: socket,
                                 client: pid,
                                 flow_control: flow} = state) do
    bin = flow.stream_id |> Goaway.new |> Encodable.to_bin
    :ssl.send(socket, bin)

    close(state)
    send(pid, {:closed, self()})

    {:stop, :normal, state}
  end
  def sendf(_else, state) do
    {:noreply, [], state}
  end

  def close(state) do
    Hpack.close(state.ref)
    for stream <- state.flow_control.active_streams do
      Stream.close(state.ref, stream)
    end
  end

  # recv

  @spec recv(frame, t) :: {:noreply, [], t}
  def recv(%Frame.RstStream{}, state) do
    Logger.error("recv unstarted stream rst")
    {:noreply, [], state}
  end

  def recv(%Frame.Ping{ack: true}, %{client: pid} = state) do
    send(pid, {:pong, self()})
    {:noreply, [], state}
  end
  def recv(%Frame.Ping{ack: false}, %{client: pid} = state) do
    send(pid, {:ping, self()})
    {:noreply, [], state}
  end

  # nil settings means use default
  def recv(%Frame.Settings{ack: false, settings: nil},
           %{flow_control: flow} = state) do

    bin = Frame.Settings.ack |> Encodable.to_bin
    :ssl.send(state.socket, bin)

    case flow.settings.max_concurrent_streams do
      :infinite ->
        GenStage.ask(state.queue, 2_000_000_000)
      max ->
        to_ask = max - flow.active_stream_count
        GenStage.ask(state.queue, to_ask)
    end

    {:noreply, [], state}
  end
  def recv(%Frame.Settings{ack: false, settings: settings},
           %{flow_control: flow, ref: ref} = state) do

    old_settings = flow.settings
    flow = Connection.FlowControl.update_settings(flow, settings)

    notify_settings_change(ref, old_settings, flow)

    pid = Hpack.via_tuple(ref, :encoder)
    Hpack.update_max_table_size(pid, settings.max_header_list_size)

    bin = Frame.Settings.ack |> Encodable.to_bin
    :ssl.send(state.socket, bin)

    to_ask = settings.max_concurrent_streams - flow.active_stream_count
    GenStage.ask(state.queue, to_ask)

    {:noreply, [], %{state | flow_control: flow}}
  end
  def recv(%Frame.Settings{ack: true}, state) do
    # Do nothing on ACK. Might change in the future.
    {:noreply, [], state}
  end

  def recv(%Goaway{last_stream_id: id,
                   error_code: error,
                   debug_data: debug}, %{client: pid} = state) do
    log_goaway(error, id, debug)
    close(state)
    send(pid, {:closed, self()})

    {:stop, :normal, state}
  end

  def recv(%Frame.WindowUpdate{window_size_increment: inc}, state) do
    flow = Connection.FlowControl.increment_window(state.flow_control, inc)
    {:noreply, [], %{state | flow_control: flow}}
  end

  def recv(_else, state), do: {:noreply, [], state}

  def notify_settings_change(ref,
                             %{initial_window_size: old_window},
                             %{settings: settings} = flow) do
    max_frame_size = settings.max_frame_size
    new_window = settings.initial_window_size
    window_diff = new_window - old_window

    for stream_id <- flow.active_streams do
      pid = Stream.via_tuple(ref, stream_id)
      Stream.cast_recv(pid, {:settings_change, window_diff, max_frame_size})
    end
  end

  defp do_send_headers(request, %{flow_control: flow} = state) do
    flow =
      flow
      |> Connection.FlowControl.add(request)
      |> Connection.FlowControl.process(state)

    %{state | flow_control: flow}
  end

  def log_goaway(code, id, bin) do
    error = Error.string(code)
    Logger.error "Got GOAWAY, #{error}, Last Stream: #{id}, Rest: #{bin}"
  end

  def handle_info({:finished, response},
                  %{client: pid, flow_control: flow} = state) do

    send(pid, {:end_stream, response})

    flow =
      flow
      |> Connection.FlowControl.decrement_active_stream_count
      |> Connection.FlowControl.remove_active(response.id)
      |> Connection.FlowControl.process(state)

    GenStage.ask(state.queue, 1)

    {:noreply, [], %{state | flow_control: flow}}
  end

  def handle_info({:push_promise, stream}, %{client: pid} = state) do
    send(pid, {:push_promise, stream})
    {:noreply, [], state}
  end

  def handle_info({:tcp, _socket, _bin}, state) do
    {:noreply, [], state}
  end

  def handle_info({:tcp_closed, _socket}, state) do
    handle_disconnect(state)
  end

  def handle_info({:ssl, _socket, bin}, state) do
    do_recv_ssl(bin, state)
  end

  def handle_info({:ssl_closed, _socket}, state) do
    handle_disconnect(state)
  end

  defp do_recv_ssl(bin, %{socket: socket} = state) do
    bin = state.buffer <> bin
    case parse_ssl(socket, bin, state) do
      {:error, bin, state} ->
        :ssl.setopts(socket, [{:active, :once}])
        {:noreply, [], %{state | buffer: bin}}
    end
  end

  def parse_ssl(socket, bin, state) do
    case FrameParser.parse(bin) do
      {:ok, frame, rest} ->
        state = handle_response(frame, state)
        parse_ssl(socket, rest, state)
      {:error, bin} ->
        {:error, bin, state}
    end
  end

  def handle_response(frame, _state) when is_binary(frame) do
    Logger.info "Got binary: #{inspect(frame)}"
  end
  def handle_response(frame, state) do
    #  parsed_frame =
    #    case frame.type do
    #      @data -> Frame.Data.new(frame)
    #      @headers -> Frame.Headers.new(frame)
    #      @rst_stream -> Frame.RstStream.new(frame)
    #      @settings ->
    #        case Frame.Settings.new(frame) do
    #          {:ok, settings_frame} -> settings_frame
    #          _else -> :error
    #        end
    #      @push_promise -> Frame.PushPromise.new(frame)
    #      @ping -> Frame.Ping.new(frame)
    #      @goaway -> Frame.Goaway.new(frame)
    #      @window_update -> Frame.WindowUpdate.new(frame)
    #      @continuation -> Frame.Continuation.new(frame)
    #      _ ->
    #        Logger.info("Unknown frame: #{inspect(frame)}")
    #        :error
    #    end

    process(frame, state)
  end

  @spec process(frame, t) :: :ok
  def process(%Frame.Data{stream_id: 0}, state) do
    # This is an error
    state
  end
  def process(%Frame.Data{stream_id: stream_id} = frame, state) do
    pid = Stream.via_tuple(state.ref, stream_id)
    send_window_update(state.socket, frame)
    Stream.cast_recv(pid, frame)
    state
  end

  def process(%Frame.Headers{} = frame, state) do
    pid = Stream.via_tuple(state.ref, frame.stream_id)
    Stream.cast_recv(pid, frame)
    state
  end

  def process(%Frame.RstStream{} = frame, state) do
    pid = Stream.via_tuple(state.ref, frame.stream_id)
    Stream.cast_recv(pid, frame)
    state
  end

  def process(%Frame.Settings{} = frame, state) do
    # Process immediately
    {:noreply, [], state} = recv(frame, state)
    state
  end

  def process(%Frame.PushPromise{stream_id: stream_id} = frame, state) do
    {:ok, pid} = StreamSupervisor.start_stream(state, stream_id)

    flow = Connection.FlowControl.add_active(state.flow_control, stream_id)

    Stream.cast_recv(pid, frame)
    %{state | flow_control: flow}
  end

  def process(%Frame.Ping{} = frame, state) do
    # Process immediately
    recv(frame, state)
    state
  end

  def process(%Frame.Goaway{} = frame, state) do
    GenServer.cast(self(), {:recv, frame})
    state
  end

  def process(%Frame.WindowUpdate{stream_id: 0} = frame, state) do
    Stream.cast_recv(self(), frame)
    state
  end
  def process(%Frame.WindowUpdate{stream_id: stream_id} = frame, state) do
    pid = Stream.via_tuple(state.ref, stream_id)
    Stream.cast_recv(pid, frame)
    state
  end

  def process(%Frame.Continuation{stream_id: stream_id} = frame, state) do
    pid = Stream.via_tuple(state.ref, stream_id)
    Stream.cast_recv(pid, frame)
    state
  end

  def process(:error, state), do: state

  def send_window_update(_socket, %Data{data: nil}), do: :ok
  def send_window_update(socket, %Data{stream_id: sid,
                                       data: data}) when byte_size(data) > 0 do
    bin = data |> WindowUpdate.new |> Encodable.to_bin
    :ssl.send(socket, bin)

    s_bin =
      sid
      |> WindowUpdate.new(byte_size(data))
      |> Encodable.to_bin
    :ssl.send(socket, s_bin)
  end
  def send_window_update(_socket, %Data{data: _data}), do: :ok

  def handle_disconnect(%{client: pid} = state) do
    Logger.debug "Socket closed, not reopening, informing client"
    send(pid, {:closed, self()})
    close(state)
    {:noreply, [], %{state | socket: nil}}
  end
end
