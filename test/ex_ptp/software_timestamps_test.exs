defmodule ExPtp.SoftwareTimestampsTest do
  use ExUnit.Case, async: true

  alias ExPtp.{Port, Sim, Transport}
  alias ExPtp.Servo.Profile

  # A simulated node that declares what a real transport would
  defmodule Declared do
    @behaviour ExPtp.Transport
    defp h({sim, id, _, _}), do: {sim, id}

    @impl true
    def attach(x, pid), do: ExPtp.Sim.Node.attach(h(x), pid)
    @impl true
    def send_msg(x, c, b, o), do: ExPtp.Sim.Node.send_msg(h(x), c, b, o)
    @impl true
    def now(x), do: ExPtp.Sim.Node.now(h(x))
    @impl true
    def schedule(x, d, m), do: ExPtp.Sim.Node.schedule(h(x), d, m)
    @impl true
    def adjust_frequency(x, p), do: ExPtp.Sim.Node.adjust_frequency(h(x), p)
    @impl true
    def step_clock(x, d), do: ExPtp.Sim.Node.step_clock(h(x), d)

    @impl true
    def timestamping({_sim, _id, kind, _scale}), do: kind
    @impl true
    def timescale({_sim, _id, _kind, scale}), do: scale
  end

  defp port(opts) do
    sim = Sim.start()
    {sim_mod, handle} = Sim.add_node(sim, :n, [])
    assert sim_mod == ExPtp.Sim.Node
    {sim_h, id} = handle
    {kind, scale, opts} = {opts[:kind], opts[:scale], Keyword.drop(opts, [:kind, :scale])}

    {:ok, pid} =
      Port.start_link(
        [transport: {Declared, {sim_h, id, kind, scale}}, clock_identity: <<1::64>>] ++ opts
      )

    pid
  end

  test "servo profiles: software gains, thresholds and filter differ from hardware" do
    hw = Profile.get(:hardware)
    sw = Profile.get(:software)
    assert Profile.gains(hw, -3) == ExPtp.Servo.gains(-3)
    {kp, ki} = Profile.gains(sw, -3)
    assert kp < 0.5 and ki < 0.001
    assert hw.lock_threshold_ns == 500 and hw.outlier == nil
    assert sw.lock_threshold_ns >= 50_000 and sw.outlier != nil
  end

  test "outlier filter: spikes are rejected, a sustained jump gets through" do
    alias ExPtp.Servo.Outlier
    cfg = %{window: 8, factor: 4, floor_ns: 1000, min_samples: 3, max_run: 2}
    o = Enum.reduce([100, 90, 110, 95], Outlier.new(cfg), &elem(Outlier.check(&2, &1), 1))
    {:reject, o} = Outlier.check(o, 80_000)
    {:reject, o} = Outlier.check(o, 80_000)
    assert {:ok, _} = Outlier.check(o, 80_000)
  end

  test "the port announces the timescale its transport delivers" do
    p = port(kind: :hardware, scale: {:ptp, 37, true})
    tp = Port.info(p).time_properties

    assert {tp.ptp_timescale, tp.current_utc_offset, tp.current_utc_offset_valid} ==
             {true, 37, true}

    p = port(kind: :software, scale: :arb)
    assert Port.info(p).time_properties.ptp_timescale == false

    assert Transport.timescale({ExPtp.Sim.Node, {nil, nil}}) == {:ptp, 37, false}
    assert Transport.timestamping({ExPtp.Sim.Node, {nil, nil}}) == :hardware
  end

  test "an explicit :time_properties option wins" do
    tp = %ExPtp.DataSets.TimeProperties{current_utc_offset: 35}
    p = port(kind: :software, scale: :arb, time_properties: tp)
    assert Port.info(p).time_properties == tp
  end

  test "ExPtp.Transport.Udp is software timestamped and TAI by default" do
    {:ok, t} =
      ExPtp.Transport.Udp.start_link(
        iface_ip: {127, 0, 0, 1},
        event_port: 39319,
        general_port: 39320
      )

    assert Transport.timestamping({ExPtp.Transport.Udp, t}) == :software
    assert Transport.timescale({ExPtp.Transport.Udp, t}) == {:ptp, 37, false}
    now = ExPtp.Timestamp.to_ns(ExPtp.Transport.Udp.now(t))
    assert_in_delta now - System.os_time(:nanosecond), 37_000_000_000, 50_000_000
    assert abs(ExPtp.Transport.Udp.clock_error_ns(t)) < 50_000_000

    {:ok, u} =
      ExPtp.Transport.Udp.start_link(
        iface_ip: {127, 0, 0, 1},
        event_port: 39321,
        general_port: 39322,
        timescale: :arb
      )

    assert Transport.timescale({ExPtp.Transport.Udp, u}) == :arb
    now = ExPtp.Timestamp.to_ns(ExPtp.Transport.Udp.now(u))
    assert_in_delta now - System.os_time(:nanosecond), 0, 50_000_000
  end
end
