defmodule ExPtp.Transport.Udp do
  @moduledoc """
  An `ExPtp.Transport` over UDP/IPv4 multicast sockets (224.0.1.129, event port
  319, general port 320) with software timestamps. Used by the interop tests
  against linuxptp; no privileges needed beyond binding ports 319 and 320.

  Timestamps:

  - receive: `SO_TIMESTAMP` (kernel, CLOCK_REALTIME, microseconds), mapped to
    the port's clock;
  - transmit: `System.os_time/1` read immediately before `sendto` (no
    `SO_TIMESTAMPING` error queue), mapped to the port's clock. This is about
    40 us early; `ExPtp.Servo.Profile` `:software` is meant for that jitter.

  The port's clock is a software clock on top of CLOCK_REALTIME with an offset
  and a rate adjustment, so the servo can steer it without privileges
  (`adjust_frequency/2`, `step_clock/2`).

  Timescale (see `ExPtp.Transport.timescale/1`): by default the clock is TAI,
  CLOCK_REALTIME plus `:tai_offset_s` (37), because the Announce of a port on
  this transport promises the PTP timescale; `:utc_offset_valid` (false) says whether
  that offset is announced as known. With `timescale: :arb` the clock is
  CLOCK_REALTIME as it is and the Announce says arbitrary timescale (what ptp4l
  does with `-S`). `clock_error_ns/1` is the port's clock minus CLOCK_REALTIME
  minus the TAI offset, zero when it agrees with a master that uses CLOCK_REALTIME
  (all containers share the host kernel clock).

  Start with `start_link(iface_ip: {10, 89, 0, 2})` (options `:group`, `:event_port` and
  `:general_port` for tests without privileges); the handle for
  `ExPtp.Port` is the pid.
  """
  use GenServer
  @behaviour ExPtp.Transport

  alias ExPtp.Timestamp

  @group {224, 0, 1, 129}
  @ptp_event 319
  @ptp_general 320

  defstruct [
    :iface,
    :event,
    :general,
    :owner,
    :dest,
    ports: {@ptp_event, @ptp_general},
    tai_ns: 0,
    timescale: :ptp,
    utc_valid: false,
    tai_s: 37,
    off_ns: 0.0,
    ppb: 0.0,
    t0: 0,
    sel: %{},
    rx_errors: 0
  ]

  # -- Transport callbacks ----------------------------------------------------------------------

  @impl ExPtp.Transport
  def attach(pid, owner), do: GenServer.call(pid, {:attach, owner})

  @impl ExPtp.Transport
  def send_msg(pid, channel, bin, _opts), do: GenServer.call(pid, {:send, channel, bin})

  @impl ExPtp.Transport
  def now(pid), do: GenServer.call(pid, :now)

  @impl ExPtp.Transport
  def schedule(pid, delay_ns, msg), do: GenServer.cast(pid, {:schedule, delay_ns, msg})

  @impl ExPtp.Transport
  def adjust_frequency(pid, ppb), do: GenServer.call(pid, {:freq, ppb})

  @impl ExPtp.Transport
  def timestamping(_pid), do: :software

  @impl ExPtp.Transport
  def timescale(pid), do: GenServer.call(pid, :timescale)

  @impl ExPtp.Transport
  def step_clock(pid, delta_ns), do: GenServer.call(pid, {:step, delta_ns})

  @doc "The port's clock minus CLOCK_REALTIME, in ns."
  def clock_error_ns(pid), do: GenServer.call(pid, :clock_error)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  # -- server -----------------------------------------------------------------------------------

  @impl true
  def init(opts) do
    iface = Keyword.fetch!(opts, :iface_ip)
    group = Keyword.get(opts, :group, @group)
    ev_port = Keyword.get(opts, :event_port, @ptp_event)
    ge_port = Keyword.get(opts, :general_port, @ptp_general)
    {:ok, ev} = open(iface, group, ev_port)
    {:ok, ge} = open(iface, group, ge_port)

    scale = Keyword.get(opts, :timescale, :ptp)
    tai_s = Keyword.get(opts, :tai_offset_s, 37)
    tai = if scale == :ptp, do: tai_s * 1_000_000_000, else: 0

    s = %__MODULE__{
      iface: iface,
      event: ev,
      general: ge,
      dest: group,
      ports: {ev_port, ge_port},
      t0: real(),
      tai_ns: tai,
      timescale: scale,
      tai_s: tai_s,
      utc_valid: Keyword.get(opts, :utc_offset_valid, false)
    }

    {:ok, s |> arm(ev) |> arm(ge)}
  end

  defp open(iface, group, port) do
    {:ok, s} = :socket.open(:inet, :dgram, :udp)
    :ok = :socket.setopt(s, {:socket, :reuseaddr}, true)
    _ = :socket.setopt(s, {:socket, :reuseport}, true)
    :ok = :socket.setopt(s, {:socket, :timestamp}, true)
    :ok = :socket.bind(s, %{family: :inet, addr: :any, port: port})
    :ok = :socket.setopt(s, {:ip, :add_membership}, %{multiaddr: group, interface: iface})
    :ok = :socket.setopt(s, {:ip, :multicast_if}, iface)
    :ok = :socket.setopt(s, {:ip, :multicast_loop}, false)
    :ok = :socket.setopt(s, {:ip, :multicast_ttl}, 1)
    {:ok, s}
  end

  defp arm(s, sock) do
    case :socket.recvmsg(sock, 2048, 256, [], :nowait) do
      {:ok, msg} ->
        s = rx(s, sock, msg)
        arm(s, sock)

      {:select, {:select_info, _tag, ref}} ->
        %{s | sel: Map.put(s.sel, ref, sock)}

      {:error, _} ->
        %{s | rx_errors: s.rx_errors + 1}
    end
  end

  @impl true
  def handle_call({:attach, owner}, _from, s), do: {:reply, :ok, %{s | owner: owner}}
  def handle_call(:now, _from, s), do: {:reply, Timestamp.from_ns(virtual(s, real())), s}

  def handle_call(:timescale, _from, %{timescale: :ptp} = s),
    do: {:reply, {:ptp, s.tai_s, s.utc_valid}, s}

  def handle_call(:timescale, _from, s), do: {:reply, :arb, s}

  def handle_call(:clock_error, _from, s) do
    r = real()
    {:reply, virtual(s, r) - r - s.tai_ns, s}
  end

  def handle_call({:send, channel, bin}, _from, s) do
    {ev_port, ge_port} = s.ports
    {sock, port} = if channel == :event, do: {s.event, ev_port}, else: {s.general, ge_port}

    t = real()
    :ok = :socket.sendto(sock, bin, %{family: :inet, addr: s.dest, port: port})

    ts = if channel == :event, do: Timestamp.from_ns(virtual(s, t)), else: nil
    {:reply, {:ok, ts}, s}
  end

  def handle_call({:freq, ppb}, _from, s) do
    r = real()
    {:reply, :ok, %{s | off_ns: virtual(s, r) - r - s.tai_ns, t0: r, ppb: ppb * 1.0}}
  end

  def handle_call({:step, delta}, _from, s) do
    r = real()
    off = virtual(s, r) - r - s.tai_ns
    {:reply, :ok, %{s | off_ns: off + delta, t0: r}}
  end

  @impl true
  def handle_cast({:schedule, delay_ns, msg}, s) do
    Process.send_after(s.owner, {:ptp_timer, msg}, max(div(delay_ns + 999_999, 1_000_000), 0))
    {:noreply, s}
  end

  @impl true
  def handle_info({:"$socket", _sock, :select, ref}, s) do
    case Map.pop(s.sel, ref) do
      {nil, _} -> {:noreply, s}
      {sock, sel} -> {:noreply, arm(%{s | sel: sel}, sock)}
    end
  end

  def handle_info({:"$socket", _sock, :abort, _}, s), do: {:noreply, s}
  def handle_info(_, s), do: {:noreply, s}

  # -- helpers ----------------------------------------------------------------------------------

  defp rx(s, sock, %{iov: [data], ctrl: ctrl} = msg) do
    channel = if sock == s.event, do: :event, else: :general
    src = msg[:addr]

    # ignore our own multicast loop-back (disabled, but be safe)
    if src && src[:addr] == s.iface do
      s
    else
      ts =
        if channel == :event do
          kernel = kernel_ts(ctrl) || real()
          Timestamp.from_ns(virtual(s, kernel))
        end

      if s.owner, do: send(s.owner, {:ptp_rx, channel, data, ts})
      s
    end
  end

  defp rx(s, _sock, _), do: s

  # SO_TIMESTAMP: struct timeval (sec, usec), native endian 64 bit
  defp kernel_ts(ctrl) do
    Enum.find_value(ctrl, fn
      %{level: :socket, type: :timestamp, value: %{sec: sec, usec: usec}} ->
        sec * 1_000_000_000 + usec * 1000

      %{level: :socket, type: :timestamp, data: <<sec::native-64, usec::native-64>>} ->
        sec * 1_000_000_000 + usec * 1000

      _ ->
        nil
    end)
  end

  defp real, do: System.os_time(:nanosecond)

  # the port's clock: CLOCK_REALTIME + TAI offset (PTP timescale) + steering
  defp virtual(s, real_ns),
    do: real_ns + s.tai_ns + round(s.off_ns + s.ppb * (real_ns - s.t0) / 1.0e9)
end
