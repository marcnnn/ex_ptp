defmodule ExPtp.RTL.WallclockTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Bitwise
  import StreamData

  alias ExPtp.RTL.Wallclock, as: RW
  alias ExPtp.Test.RTL, as: T
  alias ExPtp.{Timestamp, Wallclock}

  @nominal 8 <<< 32
  @mod RW.build()

  # -- stimulus: one command per cycle, mostly idle ---------------------------------------

  defp inc_gen,
    do:
      one_of([
        map(integer(-200_000..200_000), &Wallclock.increment(@nominal, &1)),
        integer(0..(1 <<< 36)),
        constant(@nominal)
      ])

  defp ticks_gen, do: one_of([integer(1..6), integer(1..300), integer(1..40_000)])

  defp cmd_gen do
    frequency([
      {60, constant(%{})},
      {5, map(inc_gen(), &%{inc_wr: 1, inc_in: &1})},
      {2,
       gen all s <- integer(50..100),
               ns <- one_of([integer(0..999_999_999), integer(999_000_000..999_999_999)]) do
         %{set_wr: 1, set_sec: s, set_ns: ns}
       end},
      {3, map(integer(-(1 <<< 29)..((1 <<< 29) - 1)), &%{step_wr: 1, step_ns: &1})},
      {4,
       gen all d <- integer(-(1 <<< 28)..(1 <<< 28)), k <- ticks_gen() do
         Map.merge(%{slew_wr: 1}, RW.slew_args(d, k)) |> Map.put(:delta, d)
       end},
      {3, constant(%{snap_wr: 1})},
      {4, map(integer(1..3), &%{cap: &1})},
      {2, map(integer(1..3), &%{cap_clr: &1})},
      {2, map(integer(0..999_999_999), &%{pps_width: &1})}
    ])
  end

  defp stim_gen(n) do
    gen all cmds <- list_of(cmd_gen(), length: n),
            first <- inc_gen() do
      boot = %{set_wr: 1, set_sec: 60, set_ns: 999_999_000, inc_wr: 1, inc_in: first}
      [boot | cmds]
    end
  end

  # -- model ------------------------------------------------------------------------------

  defp zero_snap, do: {0, 0, 0}
  defp snap(w), do: {w.seconds, w.nanoseconds, w.fraction}

  # Expected outputs per event (before the edge) from the BEAM models; events start after reset.
  defp expected(cmds) do
    init = %{
      w: Wallclock.new(),
      inc: @nominal,
      snap: zero_snap(),
      cap: {zero_snap(), zero_snap()},
      valid: 0,
      pps_tick: 0
    }

    {outs, _} =
      Enum.map_reduce(cmds, init, fn c, s ->
        w = s.w
        width = Map.get(c, :pps_width, 0)

        out = %{
          now_sec: w.seconds,
          now_ns: w.nanoseconds,
          now_frac: w.fraction,
          snap_sec: elem(s.snap, 0),
          snap_ns: elem(s.snap, 1),
          snap_frac: elem(s.snap, 2),
          cap_valid: s.valid,
          pps_tick: s.pps_tick,
          pps: if(w.nanoseconds < width, do: 1, else: 0),
          slew_busy: if(w.slew_ticks > 0, do: 1, else: 0)
        }

        out =
          for {i, {sec, ns, fr}} <- [{0, elem(s.cap, 0)}, {1, elem(s.cap, 1)}], reduce: out do
            o ->
              Map.merge(o, %{:"cap#{i}_sec" => sec, :"cap#{i}_ns" => ns, :"cap#{i}_frac" => fr})
          end

        # the tick that would happen without a set (for pps_tick)
        t = Wallclock.tick(w, s.inc)
        t = if c[:step_wr] == 1, do: Wallclock.step_phase(t, c.step_ns), else: t

        w2 =
          cond do
            c[:set_wr] == 1 -> Wallclock.new(Timestamp.new(c.set_sec, c.set_ns))
            true -> t
          end

        w2 =
          if c[:slew_wr] == 1 and w.slew_ticks == 0 and c[:set_wr] != 1,
            do: Wallclock.slew(w2, c.delta, c.slew_ticks),
            else: w2

        sn = if c[:snap_wr] == 1, do: snap(w), else: s.snap
        cap = c[:cap] || 0
        c0 = if (cap &&& 1) == 1, do: snap(w), else: elem(s.cap, 0)
        c1 = if (cap &&& 2) == 2, do: snap(w), else: elem(s.cap, 1)
        valid = (s.valid ||| cap) &&& bnot(c[:cap_clr] || 0) &&& 3

        {out,
         %{
           w: w2,
           inc: if(c[:inc_wr] == 1, do: c.inc_in, else: s.inc),
           snap: sn,
           cap: {c0, c1},
           valid: valid,
           pps_tick: if(t.seconds > w.seconds, do: 1, else: 0)
         }}
      end)

    outs
  end

  # pps_width must persist like an input does; make the generator's value sticky
  defp sticky(cmds) do
    {out, _} =
      Enum.map_reduce(cmds, 0, fn c, width ->
        width = Map.get(c, :pps_width, width)
        {Map.put(c, :pps_width, width), width}
      end)

    out
  end

  defp run(cmds, sim) do
    cmds = sticky(cmds)
    stim = T.stimulus(@mod, Enum.map(cmds, &Map.delete(&1, :delta)))
    {cmds, stim, sim.(stim)}
  end

  defp verify(cmds, out) do
    exp = expected(cmds)
    # events 0 and 1 are in reset
    got = Enum.drop(out, 2)

    for {{e, g}, i} <- Enum.zip(exp, got) |> Enum.with_index() do
      assert Map.take(g, Map.keys(e)) == e, "event #{i}: #{inspect(cmds |> Enum.at(i))}"
    end
  end

  property "BEAM simulation equals ExPtp.Wallclock cycle by cycle" do
    check all(cmds <- stim_gen(250), max_runs: 40) do
      {cmds, _, out} = run(cmds, &T.beam(@mod, &1))
      verify(cmds, out)
    end
  end

  test "carries over the second, steps and slews exactly" do
    inc = Wallclock.increment(@nominal, 50_000)

    cmds =
      [%{set_wr: 1, set_sec: 7, set_ns: 999_999_990, inc_wr: 1, inc_in: inc}] ++
        List.duplicate(%{}, 6) ++
        [Map.merge(%{slew_wr: 1, delta: -1500}, RW.slew_args(-1500, 7))] ++
        List.duplicate(%{}, 12) ++
        [%{step_wr: 1, step_ns: -(1 <<< 29)}, %{step_wr: 1, step_ns: (1 <<< 29) - 1}] ++
        List.duplicate(%{}, 3)

    {cmds, _, out} = run(cmds, &T.beam(@mod, &1))
    verify(cmds, out)
    secs = out |> Enum.drop(2) |> Enum.map(& &1.now_sec)
    assert 8 in secs
    assert Enum.any?(Enum.drop(out, 2), &(&1.pps_tick == 1))
    assert Enum.any?(Enum.drop(out, 2), &(&1.slew_busy == 1))
  end

  test "below the epoch the clock clamps to zero like the model" do
    cmds = [
      %{set_wr: 1, set_sec: 0, set_ns: 100},
      %{step_wr: 1, step_ns: -1000},
      %{},
      %{}
    ]

    {cmds, _, out} = run(cmds, &T.beam(@mod, &1))
    verify(cmds, out)
    assert Enum.at(out, 5).now_ns == 8
  end

  test "slew_args: q and r reproduce the model's per-tick shares" do
    for {d, k} <- [{-1500, 7}, {1, 3}, {123_456, 1}, {-999, 1000}, {5, 64}] do
      %{slew_q: q, slew_r: r, slew_ticks: k} = RW.slew_args(d, k)
      assert q * k + r == d <<< 32
      assert r in 0..(k - 1)
    end

    assert_raise FunctionClauseError, fn -> RW.slew_args(1 <<< 29, 4) end
  end

  @tag :verilator
  @tag timeout: 300_000
  property "Verilator equals the BEAM simulator" do
    check all(cmds <- stim_gen(300), max_runs: 6) do
      {_, stim, _} = run(cmds, fn _ -> nil end)
      T.cosim(@mod, stim)
    end
  end
end
