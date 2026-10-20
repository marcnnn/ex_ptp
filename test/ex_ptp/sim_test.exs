defmodule ExPtp.SimTest do
  use ExUnit.Case, async: true

  alias ExPtp.{Port, Sim, Timestamp}

  @s 1_000_000_000

  defp id(n), do: <<n::64>>

  defp node(sim, n, opts) do
    {{name, node_opts}, opts} = Keyword.pop!(opts, :node)
    t = Sim.add_node(sim, name, node_opts)
    {:ok, pid} = Port.start_link([transport: t, clock_identity: id(n)] ++ opts)

    pid
  end

  # True offsets `a - b` sampled once per simulated second.
  defp offsets(sim, a, b, seconds) do
    for _ <- 1..seconds do
      Sim.run_for(sim, @s)
      Sim.offset_ns(sim, a, b)
    end
  end

  defp max_abs(list), do: list |> Enum.map(&abs/1) |> Enum.max()

  defp pair(opts \\ []) do
    sim =
      Sim.start(
        Keyword.merge([seed: 7, delay_ns: 5_000, jitter_ns: 200], Keyword.get(opts, :net, []))
      )

    common = [profile: :aes67] ++ Keyword.get(opts, :port, [])

    m =
      node(
        sim,
        1,
        [node: {:m, [drift_ppm: Keyword.get(opts, :mdrift, -20)]}, clock_class: 6] ++ common
      )

    s =
      node(
        sim,
        2,
        [
          node:
            {:s,
             [
               drift_ppm: Keyword.get(opts, :sdrift, 50),
               initial_offset_ns: 3_000_000,
               ts_noise_ns: 4
             ]},
          clock_class: 248
        ] ++ common ++ Keyword.get(opts, :slave, [])
      )

    {sim, m, s}
  end

  test "AES67 profile: slave locks to master with +50/-20 ppm drift, jitter and 3 ms initial offset" do
    {sim, m, s} = pair()
    # roles are decided after the announce timeout, then sync starts
    _ = offsets(sim, :s, :m, 25)
    assert Port.state(m) == :master
    assert Port.state(s) == :slave
    window = offsets(sim, :s, :m, 40)
    IO.puts("2 clocks, float servo, 25..65 s: max |offset| #{max_abs(window)} ns")
    assert max_abs(window) < 300
    info = Port.info(s)
    assert info.locked
    assert info.parent == {id(1), 1}
    assert info.grandmaster == id(1)
    assert info.steps_removed == 1
    # mean path delay: 5 us + mean jitter 100 ns
    assert_in_delta info.mean_path_delay_ns, 5_100, 150
    # the servo compensates the 70 ppm frequency difference
    assert_in_delta info.freq_ppb, -70_000, 1_000
  end

  test "opposite drifts of +-50 ppm with the fixed point servo" do
    {sim, _m, s} = pair(mdrift: 50, sdrift: -50, slave: [servo: :fixed])
    _ = offsets(sim, :s, :m, 30)
    window = offsets(sim, :s, :m, 40)
    IO.puts("2 clocks, fixed servo, 30..70 s: max |offset| #{max_abs(window)} ns")
    assert max_abs(window) < 300
    assert Port.state(s) == :slave
  end

  test "convergence time: offset stays below 1 us from a given sync interval on" do
    {sim, _m, _s} = pair()

    trace =
      for _ <- 1..480 do
        Sim.run_for(sim, 125_000_000)
        Sim.offset_ns(sim, :s, :m)
      end

    settled = Enum.find(0..479, fn i -> trace |> Enum.drop(i) |> max_abs() < 1_000 end)
    IO.puts("settled below 1 us after #{settled} sync intervals (#{settled / 8} s from start)")
    assert settled < 240
    assert trace |> Enum.drop(settled) |> max_abs() < 1_000
  end

  test "asymmetric path: offset error is half the delay asymmetry" do
    {sim, _m, _s} = pair()
    Sim.set_link(sim, :m, :s, delay_ns: 10_000)
    Sim.set_link(sim, :s, :m, delay_ns: 4_000)
    _ = offsets(sim, :s, :m, 30)
    window = offsets(sim, :s, :m, 20)
    mean = Enum.sum(window) / length(window)
    # measured offset 0 means true offset = -(10000 - 4000) / 2, plus mean jitter effects
    assert_in_delta mean, -3_000, 200
  end

  test "three clocks: best clock is the grandmaster, the others follow it" do
    sim = Sim.start(seed: 3, delay_ns: 8_000, jitter_ns: 150)
    common = [profile: :aes67]
    a = node(sim, 1, [node: {:a, [drift_ppm: 30]}, clock_class: 248, priority1: 128] ++ common)
    b = node(sim, 2, [node: {:b, [drift_ppm: -40]}, clock_class: 6, priority1: 100] ++ common)

    c =
      node(
        sim,
        3,
        [node: {:c, [drift_ppm: 10, initial_offset_ns: 5_000_000]}, clock_class: 248] ++ common
      )

    _ = offsets(sim, :a, :b, 40)
    assert Port.state(b) == :master
    assert Port.state(a) == :slave
    assert Port.state(c) == :slave
    assert Port.info(a).grandmaster == id(2)
    assert Port.info(c).parent == {id(2), 1}
    wa = offsets(sim, :a, :b, 30)
    wc = offsets(sim, :c, :b, 30) |> Enum.concat([0])
    IO.puts("3 clocks, 40..100 s: max |offset| a #{max_abs(wa)} ns, c #{max_abs(wc)} ns")
    assert max_abs(wa) < 400
    assert max_abs(wc) < 400
  end

  test "identical clocks: identity breaks the tie, lower identity becomes master" do
    sim = Sim.start(seed: 4, delay_ns: 5_000)
    a = node(sim, 1, node: {:a, []}, profile: :aes67)
    b = node(sim, 2, node: {:b, []}, profile: :aes67)
    _ = offsets(sim, :a, :b, 15)
    assert {Port.state(a), Port.state(b)} == {:master, :slave}
  end

  test "a better clock joining later takes over; the old master becomes slave" do
    sim = Sim.start(seed: 5, delay_ns: 5_000)
    a = node(sim, 2, node: {:a, []}, profile: :aes67, clock_class: 248)
    _ = offsets(sim, :a, :a, 12)
    assert Port.state(a) == :master
    b = node(sim, 9, node: {:b, []}, profile: :aes67, clock_class: 6, priority1: 10)
    _ = offsets(sim, :a, :b, 15)
    assert Port.state(b) == :master
    assert Port.state(a) in [:uncalibrated, :slave]
    assert Port.info(a).grandmaster == id(9)
  end

  test "master loss: announce receipt timeout, slave takes over; recovery re-syncs" do
    {sim, m, s} = pair(sdrift: 30)
    _ = offsets(sim, :s, :m, 30)
    assert Port.state(s) == :slave
    Sim.set_link(sim, :m, :s, loss: 1.0)
    Sim.set_link(sim, :s, :m, loss: 1.0)
    # 3 announce intervals of 1 s plus margin
    _ = offsets(sim, :s, :m, 5)
    assert Port.state(s) == :master
    assert Port.state(m) == :master
    Sim.set_link(sim, :m, :s, loss: 0.0)
    Sim.set_link(sim, :s, :m, loss: 0.0)
    _ = offsets(sim, :s, :m, 15)
    assert Port.state(m) == :master
    assert Port.state(s) in [:uncalibrated, :slave]
  end

  test "state change events reach subscribers" do
    {sim, _m, s} = pair()
    Port.subscribe(s)
    Sim.run_for(sim, 30 * @s)
    assert_received {:ex_ptp, ^s, {:state, :master, :listening}}
    assert_received {:ex_ptp, ^s, {:state, :uncalibrated, :master}}
    assert_received {:ex_ptp, ^s, {:state, :slave, :uncalibrated}}
    assert_received {:ex_ptp, ^s, {:offset, _, _}}
  end

  test "clocks in different domains ignore each other" do
    sim = Sim.start(seed: 6, delay_ns: 5_000)
    a = node(sim, 1, node: {:a, []}, profile: :aes67)
    b = node(sim, 2, node: {:b, []}, profile: :aes67, domain_number: 4)
    _ = offsets(sim, :a, :b, 12)
    assert {Port.state(a), Port.state(b)} == {:master, :master}
    assert Port.info(a).stats.dropped > 0
  end

  test "slave-only clock stays listening without a master and follows one that appears" do
    sim = Sim.start(seed: 8, delay_ns: 5_000)
    s = node(sim, 2, node: {:s, [drift_ppm: 10]}, profile: :aes67, slave_only: true)
    _ = offsets(sim, :s, :s, 12)
    assert Port.state(s) == :listening
    _m = node(sim, 1, node: {:m, []}, profile: :aes67, clock_class: 248)
    _ = offsets(sim, :s, :m, 20)
    assert Port.state(s) in [:uncalibrated, :slave]
  end

  test "one-step master" do
    sim = Sim.start(seed: 9, delay_ns: 5_000, jitter_ns: 100)

    _m =
      node(sim, 1, node: {:m, [drift_ppm: 5]}, profile: :aes67, clock_class: 6, two_step: false)

    s = node(sim, 2, node: {:s, [drift_ppm: -5, initial_offset_ns: 100_000]}, profile: :aes67)
    _ = offsets(sim, :s, :m, 30)
    assert max_abs(offsets(sim, :s, :m, 15)) < 300
    assert Port.info(s).stats.rx[:follow_up] == nil
  end

  test "fault and recovery" do
    sim = Sim.start(seed: 10, delay_ns: 5_000)
    a = node(sim, 1, node: {:a, []}, profile: :aes67)
    _ = offsets(sim, :a, :a, 2)
    assert Port.state(a) == :listening
    Port.event(a, :fault_detected)
    assert Port.state(a) == :faulty
    _ = offsets(sim, :a, :a, 5)
    assert Port.state(a) == :faulty
    Port.event(a, :fault_cleared)
    assert Port.state(a) == :listening
    _ = offsets(sim, :a, :a, 5)
    assert Port.state(a) == :master
    Port.event(a, :designated_disabled)
    assert Port.state(a) == :disabled
  end

  test "the SMPTE ST 2059-2 profile runs on domain 127 with 250 ms announce interval" do
    sim = Sim.start(seed: 11, delay_ns: 5_000)
    p = [profile: :smpte_2059_2]
    m = node(sim, 1, [node: {:m, []}, clock_class: 6] ++ p)
    s = node(sim, 2, [node: {:s, [drift_ppm: 20, initial_offset_ns: 50_000]}] ++ p)
    _ = offsets(sim, :s, :m, 15)
    assert Port.info(m).default_ds.domain_number == 127
    assert max_abs(offsets(sim, :s, :m, 10)) < 300
    assert Port.state(s) == :slave
  end

  test "garbage and truncated packets are dropped" do
    sim = Sim.start(seed: 12)
    a = node(sim, 1, node: {:a, []}, profile: :aes67)
    send(a, {:ptp_rx, :general, <<1, 2, 3>>, nil})
    send(a, {:ptp_rx, :event, :crypto.strong_rand_bytes(60), Timestamp.new(1, 1)})
    send(a, :unrelated)
    assert Port.info(a).stats.dropped >= 1
    assert Port.state(a) == :listening
  end
end
