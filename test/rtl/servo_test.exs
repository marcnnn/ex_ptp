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
end
