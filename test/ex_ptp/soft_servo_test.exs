defmodule ExPtp.SoftServoTest do
  use ExUnit.Case, async: true
  alias ExPtp.{Clock, Servo, SoftServo, Timestamp, Wallclock}
  alias ExPtp.Clock.Wallclock, as: WC
  alias ExPtp.RTL.Servo, as: RS
  alias ExPtp.Servo.FixedPI
  alias ExPtp.Test.SoftLoop, as: L

  doctest SoftServo

  @nominal Wallclock.nominal_increment(125_000_000)

  # A clock that reports every command to the test process and applies none.
  defmodule Spy do
    @behaviour ExPtp.Clock
    def now(_), do: ExPtp.Timestamp.new(1)
    def freq(_), do: 0.0
    def adj_freq({pid, r}, ppb), do: (send(pid, {:adj_freq, ppb}) && r) || :ok
    def step({pid, r}, d), do: (send(pid, {:step, d}) && r) || :ok
    def set({pid, r}, t), do: (send(pid, {:set, t}) && r) || :ok
    def caps(_), do: [:adj_freq, :step, :set]
  end

  # Runs `n` exchanges, returns {trace of {true offset, event}, bench, servo}.
  defp run(b, s, n) do
    {rows, b, s} =
      Enum.reduce(1..n//1, {[], b, s}, fn _, {rows, b, s} ->
        {{t1, t2, t3, t4}, b} = L.exchange(b)
        {ev, s} = SoftServo.exchange(s, t1, t2, t3, t4)
        {[{L.offset_ns(b), ev} | rows], b, s}
      end)

    {Enum.reverse(rows), b, s}
  end

  defp offsets(rows), do: Enum.map(rows, &elem(&1, 0))
  defp tail_max(offs, n), do: offs |> Enum.take(-n) |> Enum.map(&abs/1) |> Enum.max()

  describe "mode S: locking a simulated slave" do
    test "same scenario and gains as the hardware loop (70 ppm apart, 3 ms off): converges and locks alike" do
      b = L.new()
      {rows, _, s} = run(b, SoftServo.new(L.slave(b), mpd_shift: 0), 70)
      offs = offsets(rows)
      st = SoftServo.status(s)

      settled = L.settled(offs, 3_000)
      peak = offs |> Enum.drop(1) |> Enum.max()

      IO.puts(
        "SoftServo loop (8 ns tick, 70 ppm apart, 3 ms initial offset, 70 intervals of 125 ms): " <>
          "peak after the step #{peak} ns, within 3 us from interval #{settled}, " <>
          "last 10 |offset| max #{tail_max(offs, 10)} ns, ppb #{Float.round(st.ppb, 1)}, steps #{st.steps}"
      )

      # the RTL loop of test/rtl/closed_loop_test.exs: within 3 us after 27 intervals, 169 ns at the end
      assert settled <= 30
      assert tail_max(offs, 10) < 300
      assert_in_delta st.ppb, -70_000, 1_000
      assert st.locked and st.steps == 1 and st.rejected == 0 and st.samples == 70
      assert_in_delta st.mpd_ns, 5_100, 150
    end

    test "lock time is comparable to the hardware loop (60 intervals at a 240 ns tick)" do
      b = L.new()

      {locked_at, _} =
        Enum.reduce_while(1..120, {nil, {b, SoftServo.new(L.slave(b), mpd_shift: 0)}}, fn k,
                                                                                          {_,
                                                                                           {b, s}} ->
          {{t1, t2, t3, t4}, b} = L.exchange(b)
          {_, s} = SoftServo.exchange(s, t1, t2, t3, t4)
          if SoftServo.status(s).locked, do: {:halt, {k, nil}}, else: {:cont, {nil, {b, s}}}
        end)

      IO.puts("SoftServo locked after #{locked_at} intervals (RTL loop: 60)")
      assert locked_at in 40..65
    end

    test "timestamp noise: the loop still locks and the residual stays within the noise" do
      b = L.new(noise_ns: 100)
      {rows, _, s} = run(b, SoftServo.new(L.slave(b)), 120)
      offs = offsets(rows)
      assert SoftServo.status(s).locked
      assert tail_max(offs, 30) < 400
      stats = SoftServo.stats(s)
      assert stats.n == 120 and stats.max_abs_ns >= 3_000_000 - 1
    end

    test "the float PI gives the same answer within a few ns" do
      b1 = L.new()
      b2 = L.new()
      {r1, _, _} = run(b1, SoftServo.new(L.slave(b1), servo: :fixed), 70)
      {r2, _, _} = run(b2, SoftServo.new(L.slave(b2), servo: :float), 70)
      assert tail_max(offsets(r2), 10) < 300
      assert abs(Enum.at(offsets(r1), 69) - Enum.at(offsets(r2), 69)) < 100
    end

    test "software profile: gains, thresholds and the outlier filter of ExPtp.Servo.Profile" do
      # 5 ppm error, 20 us timestamp noise: the slow software gains pull the offset in over minutes
      b = L.new(noise_ns: 20_000, init_offset_ns: 200_000, slave_ppb: 5_000, master_ppb: 0)
      s = SoftServo.new(L.slave(b), profile: :software)
      {rows, _, s} = run(b, s, 300)
      assert SoftServo.status(s).locked
      assert tail_max(offsets(rows), 60) < 60_000
      assert_in_delta SoftServo.status(s).ppb, -5_000, 3_000

      # a spike far outside the recent samples is dropped, the rate is left alone
      ppb = SoftServo.ppb(s)
      assert {:reject, s} = SoftServo.update(s, 5_000_000 - 1)
      assert SoftServo.ppb(s) == ppb and SoftServo.status(s).rejected == 1
    end

    test "the PI arithmetic is FixedPI's: same output for the same offsets" do
      offs = [3000.0, -1500.25, 800.5, 20.0, -7.75, 400.0]
      clock = WC.start()
      {kp, ki} = Servo.gains(-3)
      f0 = FixedPI.new(kp, ki)

      {ppbs, _, _} =
        Enum.reduce(offs, {[], SoftServo.new(clock), f0}, fn o, {acc, s, f} ->
          {:servo, s} = SoftServo.update(s, o)
          {raw, f} = FixedPI.step(f, FixedPI.err_from_scaled(ExPtp.Correction.from_ns(o)))
          {[{SoftServo.ppb(s), FixedPI.ppb(raw)} | acc], s, f}
        end)

      assert Enum.all?(ppbs, fn {a, b} -> a == b end)
    end

    test "an offset above the step threshold steps the phase and keeps the rate" do
      clock = WC.start(time: Timestamp.new(100))
      :ok = Clock.adj_freq(clock, -12_000)
      s = SoftServo.new(clock)
      {:step, s} = SoftServo.update(s, 2_500_000)
      assert Clock.now(clock) == Timestamp.add_ns(Timestamp.new(100), -2_500_000)
      assert_in_delta Clock.freq(clock), -12_000, 0.1
      st = SoftServo.status(s)
      assert st.steps == 1 and not st.locked
    end

    test "a refusing clock is reported, nothing is counted" do
      s = SoftServo.new({Spy, {self(), {:error, :nope}}})
      assert {{:error, :nope}, s2} = SoftServo.update(s, 500)
      assert SoftServo.status(s2).ppb == 0.0
      assert {{:error, :nope}, _} = SoftServo.update(s, 5_000_000)
    end

    test "a read only clock is refused in servo mode" do
      assert_raise ArgumentError, fn -> SoftServo.new({Clock.System, []}) end
      assert_raise ArgumentError, fn -> SoftServo.new(nil) end
    end
  end

  describe "mode :monitor" do
    test "records offsets and statistics and never calls the clock" do
      spy = {Spy, {self(), :ok}}
      s = SoftServo.new(spy, mode: :monitor)

      s =
        Enum.reduce([100, -200, 300_000_000, 50], s, fn o, s ->
          {:monitor, s} = SoftServo.update(s, o)
          s
        end)

      refute_received {:adj_freq, _}
      refute_received {:step, _}
      refute_received {:set, _}

      st = SoftServo.status(s)
      assert st.mode == :monitor and st.samples == 4 and st.steps == 0 and st.ppb == 0.0
      assert st.offset_ns == 50.0
      stats = SoftServo.stats(s)
      assert stats.n == 4 and stats.max_abs_ns == 300_000_000.0
      assert_in_delta stats.mean_ns, 74_999_987.5, 0.01
    end

    test "a free running slave: the clock ends up exactly where it would without a servo" do
      b1 = L.new()
      b2 = L.new()
      {rows, b1, s} = run(b1, SoftServo.new(L.slave(b1), mode: :monitor), 40)
      b2 = Enum.reduce(1..40, b2, fn _, b -> b |> L.exchange() |> elem(1) end)

      assert WC.state(elem(L.slave(b1), 1)) == WC.state(elem(L.slave(b2), 1))
      assert WC.increment(elem(L.slave(b1), 1)) == @nominal

      # the offset it records is the true one at the Sync (path delay symmetric, jitter small); 70 ppm of 125 ms later
      st = SoftServo.status(s)
      assert Enum.all?(rows, fn {_, ev} -> ev == :monitor end)
      assert_in_delta st.offset_ns, List.last(offsets(rows)) - 0.00007 * 125_000_000, 400
      assert st.steps == 0 and st.ppb == 0.0
    end

    test "works on the read only system clock" do
      s = SoftServo.new({Clock.System, []}, mode: :monitor)
      {:monitor, s} = SoftServo.update(s, 12.5, 100.0)
      assert SoftServo.status(s).mpd_ns == 100.0
    end

    test "switching modes at run time" do
      clock = WC.start()
      :ok = Clock.adj_freq(clock, -30_000)
      s = SoftServo.new(clock)
      {:servo, s} = SoftServo.update(s, 100)
      rate = Clock.freq(clock)

      s = SoftServo.set_mode(s, :monitor)
      {:monitor, s} = SoftServo.update(s, 5000)
      assert Clock.freq(clock) == rate

      # resuming restarts the integrator from the rate the clock has
      s = SoftServo.set_mode(s, :servo)
      assert SoftServo.status(s).mode == :servo
      {:servo, s} = SoftServo.update(s, 0)
      assert_in_delta SoftServo.ppb(s), rate, 0.5
    end
  end

  describe "handover" do
    # The hardware servo in the loop: FixedPI on the offset, the rate written as the wallclock increment.
    defp hw_run(b, f, n) do
      {rows, b, f} =
        Enum.reduce(1..n//1, {[], b, f}, fn _, {rows, b, f} ->
          {{t1, t2, t3, t4}, b} = L.exchange(b)
          mpd = ExPtp.Delay.e2e_mean_path_delay(t1, t2, t3, t4)
          off = ExPtp.Delay.offset_from_master(t1, t2, 0, mpd)
          {raw, f} = FixedPI.step(f, FixedPI.err_from_scaled(off))
          :ok = Clock.adj_freq(L.slave(b), FixedPI.ppb(raw))
          {[{L.offset_ns(b), FixedPI.ppb(raw), ExPtp.Correction.to_ns(off)} | rows], b, f}
        end)

      {Enum.reverse(rows), b, f}
    end

    defp converged(n) do
      # a loop that ran a while in software, near its steady state
      b = L.new(init_offset_ns: 20_000)
      {rows, b, s} = run(b, SoftServo.new(L.slave(b)), n)
      {offsets(rows), b, s}
    end

    test "H to S: a software servo takes over at the hardware servo's rate, no step, bounded rate change" do
      {kp, ki} = Servo.gains(-3)
      b = L.new(init_offset_ns: 20_000)
      {hw, b, _} = hw_run(b, FixedPI.new(kp, ki), 60)
      hw_ppb = hw |> List.last() |> elem(1)
      rate = Clock.freq(L.slave(b))
      assert_in_delta rate, hw_ppb, 0.2

      s = SoftServo.new(L.slave(b))
      assert_in_delta SoftServo.ppb(s), rate, 0.001

      {rows, _, s} = run(b, s, 40)
      offs = offsets(rows)
      first = rows |> hd() |> elem(0)

      # no step in phase: the software servo never stepped, the offset does not leave the hardware's band
      assert SoftServo.status(s).steps == 0
      hw_band = hw |> Enum.take(-20) |> Enum.map(fn {o, _, _} -> abs(o) end) |> Enum.max()
      assert Enum.max(Enum.map(offs, &abs/1)) <= max(2 * hw_band, 600)
      assert abs(first) < 600

      assert SoftServo.status(s).locked
    end

    test "H to S: the rate of the first software step differs from the hardware's by at most (kp + ki) * offset" do
      {kp, ki} = Servo.gains(-3)
      b = L.new(init_offset_ns: 20_000)
      {_, b, _} = hw_run(b, FixedPI.new(kp, ki), 60)
      rate = Clock.freq(L.slave(b))
      s = SoftServo.new(L.slave(b))

      {{t1, t2, t3, t4}, b} = L.exchange(b)
      {:servo, s} = SoftServo.exchange(s, t1, t2, t3, t4)
      measured = abs(SoftServo.status(s).offset_ns)
      assert abs(SoftServo.ppb(s) - rate) <= (kp + ki) * measured + 1
      assert abs(L.offset_ns(b)) < 600
    end

    test "H to S without the preload jumps the rate by about the whole correction (what the preload prevents)" do
      {kp, ki} = Servo.gains(-3)
      b = L.new(init_offset_ns: 20_000)
      {_, b, _} = hw_run(b, FixedPI.new(kp, ki), 60)
      rate = Clock.freq(L.slave(b))
      s = SoftServo.new(L.slave(b), ppb: 0.0)
      {{t1, t2, t3, t4}, _} = L.exchange(b)
      {:servo, s} = SoftServo.exchange(s, t1, t2, t3, t4)
      assert abs(SoftServo.ppb(s) - rate) > 60_000
    end

    test "S to H: the hardware servo preloaded from the increment continues the rate; no step in phase" do
      {kp, ki} = Servo.gains(-3)
      {offs, b, s} = converged(60)
      inc = WC.increment(elem(L.slave(b), 1))
      rate = Clock.freq(L.slave(b))
      assert_in_delta SoftServo.ppb(s), rate, 0.2

      # the preload the RTL gets: raw ppb whose increment is exactly the one in the wallclock
      pre = RS.preload_for(inc, @nominal)
      assert RS.inc_for(pre, @nominal) == inc
      f = FixedPI.preload(FixedPI.new(kp, ki), pre)
      {first_raw, _} = FixedPI.step(f, 0)
      assert RS.inc_for(first_raw, @nominal) == inc

      {hw, b2, _} = hw_run(b, f, 40)
      first = hw |> hd()
      measured = abs(elem(first, 2))

      # the first real sample moves the rate by (kp + ki) * offset at most
      assert abs(elem(first, 1) - FixedPI.ppb(pre)) <= (kp + ki) * measured + 1
      assert abs(elem(first, 0)) < 600
      hw_offs = Enum.map(hw, fn {o, _, _} -> abs(o) end)
      assert Enum.max(hw_offs) <= max(2 * tail_max(offs, 20), 600)
      assert abs(L.offset_ns(b2)) < 600
    end
  end

  test "the status has the fields of the hardware servo's registers" do
    s = SoftServo.new(WC.start())

    assert %{locked: false, ppb: ppb, offset_ns: nil, mpd_ns: nil, samples: 0, steps: 0} =
             SoftServo.status(s)

    assert ppb == 0.0

    assert {:no_path_delay, _} = SoftServo.sync(s, Timestamp.new(1), Timestamp.new(1, 5))

    assert SoftServo.stats(s) == %{
             n: 0,
             mean_ns: nil,
             stddev_ns: nil,
             rms_ns: nil,
             max_abs_ns: nil
           }
  end
end
