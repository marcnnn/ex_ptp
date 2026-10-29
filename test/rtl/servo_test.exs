defmodule ExPtp.RTL.ServoTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Bitwise

  alias ExHdl.RTL.Cosim
  alias ExPtp.RTL.Servo, as: RS
  alias ExPtp.Servo.{FixedPI, Lock}
  alias ExPtp.Test.RTL, as: T
  alias ExPtp.Wallclock

  @nominal 8 <<< 32

  doctest RS

  test "the rate conversion agrees with Wallclock.increment/2 within one unit" do
    for raw <- [0, 1, -1, 255, 256, -256, 25_600_000, -25_600_000, (1 <<< 27) - 1, -(1 <<< 27)],
        nominal <- [@nominal, 6 <<< 32, Wallclock.nominal_increment(156_250_000)] do
      assert abs(RS.inc_for(raw, nominal) - Wallclock.increment(nominal, raw / 256)) <= 1
    end

    assert RS.inc_for(256_000, @nominal) == Wallclock.increment(@nominal, 1000)
  end

  defp case_gen do
    gen all kp <- StreamData.integer(0..(1 <<< 22)),
            ki <- StreamData.integer(0..(1 <<< 21)),
            n <- StreamData.integer(8..30),
            errs <-
              StreamData.list_of(
                StreamData.frequency([
                  {6, StreamData.integer(-3000..3000)},
                  {2, StreamData.integer(-60_000..60_000)},
                  {1, StreamData.integer(-8_000_000..8_000_000)}
                ]),
                length: n
              ),
            gaps <- StreamData.list_of(StreamData.integer(24..60), length: n),
            thr <- StreamData.integer(20..800),
            factor <- StreamData.integer(1..4),
            needed <- StreamData.integer(1..6),
            kp2 <- StreamData.integer(0..(1 <<< 22)) do
      %{
        kp: kp,
        ki: ki,
        kp2: kp2,
        errs: errs,
        gaps: gaps,
        thr: thr,
        factor: factor,
        needed: needed
      }
    end
  end

  # stimulus and the cycle of every sample
  defp stimulus(mod, c) do
    cfg = %{
      nominal: @nominal,
      scale: RS.scale(@nominal),
      thr: c.thr * 256,
      thr_unlock: c.thr * c.factor * 256,
      needed: c.needed
    }

    {events, cycles, _} =
      c.errs
      |> Enum.zip(c.gaps)
      |> Enum.with_index()
      |> Enum.reduce({[%{load: 1, kp: c.kp, ki: c.ki}], [], 1}, fn {{e, gap}, j}, {ev, cyc, at} ->
        # after sample 3 the gains change (applied between samples)
        reload = if j == 3, do: [%{load: 1, kp: c.kp2, ki: c.ki}], else: []
        idle = List.duplicate(%{}, gap - 1 - length(reload))

        {ev ++ reload ++ idle ++ [%{err_valid: 1, err: e * 256}], cyc ++ [at + gap], at + gap}
      end)

    stim = T.stimulus(mod, Enum.map(events ++ List.duplicate(%{}, 40), &Map.merge(cfg, &1)), 3)
    {stim, cycles}
  end

  defp expected(c) do
    {rows, _, _} =
      c.errs
      |> Enum.with_index()
      |> Enum.reduce(
        {[], %FixedPI{kp: c.kp, ki: c.ki}, Lock.new(c.thr, c.needed, c.factor)},
        fn {e, j}, {rows, f, l} ->
          f = if j == 3, do: %{f | kp: c.kp2}, else: f
          {raw, f} = FixedPI.step(f, e * 256)
          l = Lock.update(l, e)
          {[%{ppb: raw, inc: RS.inc_for(raw, @nominal), locked: l.locked} | rows], f, l}
        end
      )

    Enum.reverse(rows)
  end

  @tag :verilator
  @tag timeout: 300_000
  property "Verilator: PI output, increment and lock equal FixedPI, inc_for and Lock for every sample" do
    mod = RS.build()
    {:ok, cosim} = Cosim.build(mod)

    check all(c <- case_gen(), max_runs: 12) do
      {stim, _} = stimulus(mod, c)
      {:ok, out} = Cosim.run(cosim, stim)
      exp = expected(c)

      ppbs = for o <- out, o.ppb_valid == 1, do: o.ppb
      incs = for o <- out, o.inc_wr == 1, do: o.inc
      assert ppbs == Enum.map(exp, & &1.ppb)
      assert incs == Enum.map(exp, & &1.inc)
      assert Enum.all?(out, &(&1.dropped == 0))

      # lock state a few cycles after each sample went in
      {stim_events, _} = {stim, nil}
      sample_at = for {s, i} <- Enum.with_index(stim_events), s.err_valid == 1, do: i
      assert length(sample_at) == length(exp)

      assert for(i <- sample_at, do: Enum.at(out, i + 3).locked == 1) ==
               Enum.map(exp, & &1.locked)
    end
  end

  @tag :verilator
  test "samples that arrive while one is in the kernel are dropped and counted" do
    mod = RS.build()
    {:ok, cosim} = Cosim.build(mod)
    cfg = %{nominal: @nominal, scale: RS.scale(@nominal), thr: 1000, thr_unlock: 2000, needed: 3}

    ev =
      [%{load: 1, kp: 1_000_000, ki: 200_000}] ++
        List.duplicate(%{}, 30) ++
        [%{err_valid: 1, err: 5 * 256}, %{err_valid: 1, err: 9 * 256}] ++ List.duplicate(%{}, 40)

    stim = T.stimulus(mod, Enum.map(ev, &Map.merge(cfg, &1)), 3)
    {:ok, out} = Cosim.run(cosim, stim)
    assert Enum.count(out, &(&1.dropped == 1)) <= 1
    assert Enum.count(out, &(&1.ppb_valid == 1)) >= 1
  end

  test "preload_for/2 gives the raw ppb whose increment is exactly the given one" do
    for nominal <- [@nominal, 6 <<< 32, Wallclock.nominal_increment(156_250_000)],
        ppb <- [0, 1, -1, 37.5, -12_345.6, 70_000, -524_000] do
      inc = Wallclock.increment(nominal, ppb)
      raw = RS.preload_for(inc, nominal)
      assert RS.inc_for(raw, nominal) == inc
      assert abs(FixedPI.ppb(raw) - ppb) < 40
    end
  end

  defp preload_case_gen do
    gen all kp <- StreamData.integer(0..(1 <<< 22)),
            ki <- StreamData.integer(0..(1 <<< 21)),
            ops <-
              StreamData.list_of(
                StreamData.one_of([
                  StreamData.tuple(
                    {StreamData.constant(:err), StreamData.integer(-60_000..60_000)}
                  ),
                  StreamData.tuple(
                    {StreamData.constant(:pre), StreamData.integer(-(1 <<< 24)..(1 <<< 24))}
                  )
                ]),
                min_length: 4,
                max_length: 14
              ),
            gaps <- StreamData.list_of(StreamData.integer(24..50), length: 14) do
      %{kp: kp, ki: ki, ops: ops, gaps: gaps}
    end
  end

  @tag :verilator
  @tag timeout: 300_000
  property "Verilator: a preload outputs the preload and continues the PI from it, as FixedPI with the integrator replaced" do
    mod = RS.build()
    {:ok, cosim} = Cosim.build(mod)

    cfg = %{
      nominal: @nominal,
      scale: RS.scale(@nominal),
      thr: 1000 * 256,
      thr_unlock: 2000 * 256,
      needed: 3
    }

    check all(c <- preload_case_gen(), max_runs: 12) do
      ops = Enum.zip(c.ops, c.gaps)

      events =
        [%{load: 1, kp: c.kp, ki: c.ki}] ++
          Enum.flat_map(ops, fn
            {{:err, e}, gap} -> List.duplicate(%{}, gap - 1) ++ [%{err_valid: 1, err: e * 256}]
            {{:pre, p}, gap} -> List.duplicate(%{}, gap - 1) ++ [%{pre_wr: 1, pre: p}]
          end) ++ List.duplicate(%{}, 40)

      stim = T.stimulus(mod, Enum.map(events, &Map.merge(cfg, &1)), 3)
      {:ok, out} = Cosim.run(cosim, stim)

      {exp, _} =
        Enum.map_reduce(c.ops, %FixedPI{kp: c.kp, ki: c.ki}, fn
          {:err, e}, f ->
            {raw, f} = FixedPI.step(f, e * 256)
            {raw, f}

          {:pre, p}, f ->
            FixedPI.step(FixedPI.preload(f, p), 0)
        end)

      ppbs = for o <- out, o.ppb_valid == 1, do: o.ppb
      incs = for o <- out, o.inc_wr == 1, do: o.inc
      assert ppbs == exp
      assert incs == Enum.map(exp, &RS.inc_for(&1, @nominal))
      assert Enum.all?(out, &(&1.dropped == 0))

      # a preload never changes the lock detector: it never locks without enough error samples
      n_err = Enum.count(c.ops, &match?({:err, _}, &1))
      if n_err < 3, do: assert(Enum.all?(out, &(&1.locked == 0)))
    end
  end

  @tag :verilator
  test "S to H: preloading the current increment makes the first output continue it" do
    mod = RS.build()
    {:ok, cosim} = Cosim.build(mod)
    {kp, ki} = ExPtp.Servo.gains(-3)
    f = FixedPI.new(kp, ki)

    cfg = %{
      nominal: @nominal,
      scale: RS.scale(@nominal),
      thr: 500 * 256,
      thr_unlock: 1000 * 256,
      needed: 3
    }

    for ppb <- [-70_000.0, 12_345.5, 0.0] do
      inc = Wallclock.increment(@nominal, ppb)
      pre = RS.preload_for(inc, @nominal)

      ev =
        [%{load: 1, kp: f.kp, ki: f.ki}] ++
          List.duplicate(%{}, 30) ++
          [%{pre_wr: 1, pre: pre}] ++
          List.duplicate(%{}, 30) ++
          [%{err_valid: 1, err: 400 * 256}] ++ List.duplicate(%{}, 40)

      stim = T.stimulus(mod, Enum.map(ev, &Map.merge(cfg, &1)), 3)
      {:ok, out} = Cosim.run(cosim, stim)
      [first, second] = for o <- out, o.inc_wr == 1, do: o.inc

      # the first output is the increment the wallclock already has: no step in rate
      assert first == inc

      # the first sample moves the rate by (kp + ki) * err, what the software PI does from the same state
      {raw, _} = FixedPI.step(FixedPI.preload(f, pre), 400 * 256)
      assert second == RS.inc_for(raw, @nominal)
      assert abs(FixedPI.ppb(raw) - FixedPI.ppb(pre)) <= (kp + ki) * 400 + 1
    end
  end
end
