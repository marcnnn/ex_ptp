defmodule ExPtp.ModelsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Bitwise

  alias ExPtp.{Correction, Delay, MediaClock, Servo, Timestamp, Wallclock}
  alias ExPtp.Servo.{FixedPI, Lock, PI}
  alias NxFixed.Num

  doctest ExPtp.Delay
  doctest ExPtp.Wallclock
  doctest ExPtp.MediaClock
  doctest ExPtp.MediaClock.Nco
  doctest ExPtp.Servo
  doctest ExPtp.Servo.FixedPI
  doctest ExPtp.Servo.PI
  doctest ExPtp.Servo.Lock
  doctest ExPtp.Servo.Profile
  doctest ExPtp.Servo.Outlier

  defp ts(ns), do: Timestamp.from_ns(ns)

  describe "delay and offset" do
    test "E2E with asymmetric path: offset error is half the asymmetry" do
      # slave ahead by 1000 ns, master->slave 600 ns, slave->master 400 ns
      {t1, t4} = {ts(10_000), ts(21_000 - 1000 + 400)}
      t2 = ts(10_000 + 600 + 1000)
      t3 = ts(30_000 + 1000)
      mpd = Delay.e2e_mean_path_delay(t1, t2, t3, ts(30_000 + 400))
      assert Correction.to_ns(mpd) == 500.0
      off = Delay.offset_from_master(t1, t2, 0, mpd)
      # true offset 1000, measured 1100 = 1000 + (600 - 400) / 2
      assert Correction.to_ns(off) == 1100.0
      _ = t4
    end

    test "corrections are subtracted (transparent clock residence time)" do
      {t1, t2, t3, t4} = {ts(0), ts(1500), ts(2000), ts(2500)}
      c_sync = Correction.from_ns(300)
      c_resp = Correction.from_ns(100)
      mpd = Delay.e2e_mean_path_delay(t1, t2, t3, t4, c_sync, c_resp)
      assert Correction.to_ns(mpd) == (1500 + 500 - 300 - 100) / 2
      off = Delay.offset_from_master(t1, t2, c_sync, mpd)
      assert Correction.to_ns(off) == 1500 - 300 - (1500 + 500 - 400) / 2
    end

    test "P2P mean path delay and rate ratio" do
      # responder 2500 ns ahead of requester, 700 ns each way, 3000 ns turnaround
      t1 = ts(0)
      t2 = ts(700 + 2500)
      t3 = ts(3200 + 3000)
      t4 = ts(6200 - 2500 + 700)
      assert Correction.to_ns(Delay.p2p_mean_path_delay(t1, t2, t3, t4)) == 700.0
      assert Delay.rate_ratio(ts(0), ts(1_000_000_100), ts(0), ts(1_000_000_000)) == 1.0000001
      assert Delay.rate_ratio(ts(5), ts(5), ts(7), ts(7)) == nil
    end

    property "recovers offset and delay for random symmetric paths" do
      check all(
              off <- integer(-1_000_000..1_000_000),
              d <- integer(0..100_000),
              t1 <- integer(10_000_000..20_000_000),
              gap <- integer(0..1_000_000)
            ) do
        t2 = ts(t1 + d + off)
        t3 = ts(t1 + d + off + gap)
        t4 = ts(t1 + d + off + gap - off + d)
        mpd = Delay.e2e_mean_path_delay(ts(t1), t2, t3, t4)
        assert mpd == Correction.from_ns(d)
        assert Delay.offset_from_master(ts(t1), t2, 0, mpd) == Correction.from_ns(off)
      end
    end
  end

  describe "wallclock" do
    @nominal Wallclock.nominal_increment(125_000_000)

    test "exactly one second per 125e6 ticks, rate adjust in ppb" do
      w = Wallclock.new() |> Wallclock.advance(@nominal, 125_000_000)
      assert Wallclock.time(w) == Timestamp.new(1, 0)

      for ppb <- [-100_000, -1, 1, 37, 50_000] do
        w = Wallclock.new() |> Wallclock.advance(Wallclock.increment(@nominal, ppb), 125_000_000)
        assert abs(Timestamp.to_ns(Wallclock.time(w)) - (1_000_000_000 + ppb)) <= 1, "#{ppb}"
      end
    end

    test "second rollover keeps the fraction" do
      w = %Wallclock{seconds: 3, nanoseconds: 999_999_999, fraction: 0xFFFFFFFF}
      w = Wallclock.tick(w, 1)
      assert {w.seconds, w.nanoseconds, w.fraction} == {4, 0, 0}
    end

    test "phase step across second boundaries and the epoch" do
      w = Wallclock.new(Timestamp.new(5, 100))
      assert Wallclock.step_phase(w, -200) |> Wallclock.time() == Timestamp.new(4, 999_999_900)
      assert Wallclock.step_phase(w, 1_999_999_950) |> Wallclock.time() == Timestamp.new(7, 50)
      assert Wallclock.step_phase(Wallclock.new(), -5) |> Wallclock.time() == Timestamp.new(0, 0)
    end

    test "slew adds exactly the requested phase over the given ticks" do
      for delta <- [-1234, 1, 999_999, 5_000_000] do
        w = Wallclock.new(Timestamp.new(2, 0)) |> Wallclock.slew(delta, 1000)
        a = Wallclock.advance(w, @nominal, 1000)
        assert a.slew_ticks == 0
        plain = Wallclock.advance(Wallclock.new(Timestamp.new(2, 0)), @nominal, 1000)
        assert Wallclock.to_fixed(a) - Wallclock.to_fixed(plain) == delta <<< 32
      end
    end

    property "advance(n) equals n single ticks, with and without slew" do
      check all(
              inc <- integer(1..(40 <<< 32)),
              n <- integer(0..300),
              slew? <- boolean(),
              delta <- integer(-5000..5000),
              ticks <- integer(1..200)
            ) do
        w0 = %Wallclock{seconds: 7, nanoseconds: 999_999_000, fraction: 12345}
        w0 = if slew?, do: Wallclock.slew(w0, delta, ticks), else: w0
        stepped = Enum.reduce(1..n//1, w0, fn _, w -> Wallclock.tick(w, inc) end)
        assert Wallclock.advance(w0, inc, n) == stepped
      end
    end

    test "step/2 returns time and state" do
      {t, w} = Wallclock.step(Wallclock.new(), @nominal)
      assert t == Timestamp.new(0, 8)
      assert w.nanoseconds == 8
    end
  end

  describe "servo" do
    test "gains follow the sync interval" do
      {kp, ki} = Servo.gains(-3)
      assert_in_delta kp, 0.7 * :math.pow(0.125, -0.3), 1.0e-12
      assert_in_delta ki, 0.3 * :math.pow(0.125, 0.4), 1.0e-12
      {kp, ki} = Servo.gains(2)
      assert_in_delta kp, 0.7 / 4, 1.0e-12
      assert_in_delta ki, 0.3 / 4, 1.0e-12
    end

    # Plant: the offset integrates (rate error + adjustment) per sync interval.
    defp simulate(step, state, drift_ppb, interval_s, n, offset0) do
      {_, _, trace} =
        Enum.reduce(1..n, {offset0, state, []}, fn _, {off, st, acc} ->
          {adj, st} = step.(st, off)
          off = off + (drift_ppb + adj) * interval_s
          {off, st, [off | acc]}
        end)

      Enum.reverse(trace)
    end

    for log <- [-3, 0] do
      test "float PI converges and stays bounded (interval 2^#{log} s)" do
        {kp, ki} = Servo.gains(unquote(log))
        i = :math.pow(2, unquote(log))
        trace = simulate(&PI.step/2, PI.new(kp, ki), 50_000.0, i, round(120 / i), 20_000.0)
        assert abs(List.last(trace)) < 1.0
        assert trace |> Enum.map(&abs/1) |> Enum.max() < 200_000.0
      end

      test "fixed PI converges to quantization noise (interval 2^#{log} s)" do
        {kp, ki} = Servo.gains(unquote(log))
        i = :math.pow(2, unquote(log))

        step = fn s, off ->
          {raw, s} = FixedPI.step(s, FixedPI.err(off))
          {FixedPI.ppb(raw), s}
        end

        trace = simulate(step, FixedPI.new(kp, ki), -50_000.0, i, round(120 / i), -20_000.0)
        assert trace |> Enum.take(-20) |> Enum.map(&abs/1) |> Enum.max() < 1.0
      end
    end

    test "integrator saturation: drift beyond the range does not wrap" do
      {kp, ki} = Servo.gains(0)
      s = FixedPI.new(kp, ki)

      {out, _} =
        Enum.reduce(1..2000, {0, s}, fn _, {_, s} -> FixedPI.step(s, FixedPI.err(8_000_000.0)) end)

      assert out == -(1 <<< 27)
    end

    test "Nx kernel (fixed) is bit-identical to the integer model, incl. saturation" do
      :rand.seed(:exsss, {1, 2, 3})
      {kp, ki} = Servo.gains(-3)

      errs =
        for i <- 1..300 do
          case rem(i, 50) do
            0 -> 8_000_000.0
            1 -> -8_000_000.0
            _ -> (:rand.uniform() - 0.5) * 2 * :math.pow(10, :rand.uniform(6))
          end
        end

      {outs, final} = Servo.run(errs, 0.0, {kp, ki}, Servo.fixed_format())

      {model, state} =
        Enum.map_reduce(errs, FixedPI.new(kp, ki), fn e, s ->
          {raw, s} = FixedPI.step(s, FixedPI.err(e))
          {FixedPI.ppb(raw), s}
        end)

      assert outs == model
      assert final == FixedPI.ppb(state.integ)
    end

    test "float and fixed instances of the kernel agree closely" do
      {kp, ki} = Servo.gains(-3)
      errs = for i <- 1..200, do: 3000.0 * :math.sin(i / 7) + 40.0
      {f, _} = Servo.run(errs, 0.0, {kp, ki}, Num.float())
      {q, _} = Servo.run(errs, 0.0, {kp, ki}, Servo.fixed_format())
      worst = Enum.zip(f, q) |> Enum.map(fn {a, b} -> abs(a - b) end) |> Enum.max()
      assert worst < 2.0
      {p64, _} = Enum.map_reduce(errs, PI.new(kp, ki), fn e, s -> PI.step(s, e) end)
      assert Enum.zip(p64, f) |> Enum.all?(fn {a, b} -> abs(a - b) < 0.5 end)
    end

    test "the kernel schedules for hardware and generates SystemVerilog" do
      t = &Nx.Defn.Composite.traverse(&1, fn x -> Nx.to_template(x) end)

      args = [
        t.(Num.constant(1.0, Servo.err_format())),
        t.(Num.zeros({}, Servo.fixed_format())),
        t.(Num.constant(0.7, Servo.gain_format())),
        t.(Num.constant(0.3, Servo.gain_format())),
        [format: Servo.fixed_format()]
      ]

      assert {:error, %{message: m}} = ExHdl.DSP.analyze_scan(&Servo.pi_step/5, args, state: 1)
      assert m =~ "feedback loop"
      # one offset per sync interval: a sample every 2 cycles is plenty
      assert {:ok, %{ii: 2}} = ExHdl.DSP.analyze_scan(&Servo.pi_step/5, args, state: 1, ii: 2)

      assert {:ok, design} =
               ExHdl.DSP.scan_to_sv(&Servo.pi_step/5, args, state: 1, ii: 2, name: "ptp_servo_pi")

      assert design.source =~ "module ptp_servo_pi"
    end

    test "lock kernel matches the lock model without hysteresis" do
      :rand.seed(:exsss, {5, 6, 7})
      errs = for _ <- 1..400, do: round((:rand.uniform() - 0.2) * 300 * 256)
      thr = 100 * 256
      samples = Enum.map(errs, &Nx.s32/1)

      {outs, _} =
        NxFixed.run_scan(&Servo.lock_step/4, samples, Nx.u8(0), [Nx.s32(thr), Nx.u8(5)])

      model =
        Enum.map_reduce(errs, Lock.new(thr, 5, 1), fn e, l ->
          l = Lock.update(l, e)
          {if(l.locked, do: 1, else: 0), l}
        end)
        |> elem(0)

      assert Enum.map(outs, &Nx.to_number/1) == model
      assert 1 in model and 0 in model
    end

    test "lock detection with hysteresis" do
      l = Lock.new(100, 3)
      l = Enum.reduce([10, 20], l, &Lock.update(&2, &1))
      refute l.locked
      l = Lock.update(l, 30)
      assert l.locked
      # between threshold and unlock level: stays locked, run restarts
      l = Lock.update(l, 150)
      assert l.locked and l.run == 0
      assert Lock.update(l, -250).locked == false
    end
  end

  describe "media clock" do
    test "RTP timestamp for 44.1, 48 and 96 kHz" do
      t = Timestamp.new(100, 500_000_000)
      assert MediaClock.rtp_timestamp(t, 48_000) == 4_824_000
      assert MediaClock.rtp_timestamp(t, 44_100) == 4_432_050
      assert MediaClock.rtp_timestamp(t, 96_000) == 9_648_000
    end

    test "wraps modulo 2^32 and applies the offset" do
      t = Timestamp.new(90_000, 0)
      assert MediaClock.rtp_timestamp(t, 48_000) == rem(90_000 * 48_000, 1 <<< 32)
      assert MediaClock.rtp_timestamp(Timestamp.new(0, 0), 48_000, -1) == 0xFFFFFFFF
    end

    property "sample_time is the first instant of the sample" do
      check all(
              rate <- member_of([44_100, 48_000, 96_000]),
              sec <- integer(0..2_000_000_000),
              n <- integer(0..999_999_999),
              ahead <- integer(0..100_000),
              offset <- integer(0..0xFFFFFFFF)
            ) do
        near = Timestamp.new(sec, n)
        rtp = MediaClock.rtp_timestamp(near, rate, offset) + ahead &&& 0xFFFFFFFF
        t = MediaClock.sample_time(rtp, rate, near, offset)
        assert MediaClock.rtp_timestamp(t, rate, offset) == rtp

        assert MediaClock.rtp_timestamp(Timestamp.add_ns(t, -1), rate, offset) != rtp

        assert Timestamp.diff_ns(t, near) >= -1_000_000_000 / rate
      end
    end

    test "NCO tracks rate and ppb adjustment" do
      inc = MediaClock.Nco.increment(48_000, 125_000_000)

      count = fn inc ->
        Enum.reduce(1..1_250_000, {1 <<< 63, 0}, fn _, {p, n} ->
          {t, p} = MediaClock.Nco.step(p, inc)
          {p, n + t}
        end)
        |> elem(1)
      end

      assert count.(inc) == 480
      fast = MediaClock.Nco.increment(48_000, 125_000_000, 50_000)
      assert fast > inc
      assert count.(fast) in 480..481
    end
  end
end
