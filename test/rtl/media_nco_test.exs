defmodule ExPtp.RTL.MediaNcoTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Bitwise

  alias ExPtp.MediaClock
  alias ExPtp.MediaClock.Nco
  alias ExPtp.RTL.MediaNco
  alias ExPtp.Test.Benches
  alias ExPtp.Test.RTL, as: T
  alias ExPtp.{Timestamp, Wallclock}

  @mod Benches.media_bench()
  @clk 125_000_000
  @nominal 8 <<< 32
  @rates [48_000, 44_100, 96_000, 8_000]

  doctest MediaNco

  defp stim(events, cfg \\ %{}), do: T.stimulus(@mod, events, 2, cfg)

  # -- the free running accumulator equals Nco.step, mclk_en is the top byte changing ------------

  defp model(cmds) do
    init = %{p: 0, r: 0, t: 0, m: 0, inc: 0, wcinc: @nominal, fprod: 0, incf: 0}

    {rows, _} =
      Enum.map_reduce(cmds, init, fn c, s ->
        row = %{phase: s.p, rtp_ts: s.r, tick: s.t, mclk_en: s.m}
        inc_eff = if c[:follow] == 1, do: s.incf, else: s.inc
        {carry, np} = Nco.step(s.p, inc_eff)
        kscale = Map.get(c, :kscale, 0)

        {row,
         %{
           p: np,
           r: s.r + carry &&& 0xFFFFFFFF,
           t: carry,
           m: if(np >>> 56 != s.p >>> 56, do: 1, else: 0),
           inc: if(c[:inc_wr] == 1, do: c.inc_in, else: s.inc),
           wcinc: if(c[:winc_wr] == 1, do: c.winc_in, else: s.wcinc),
           fprod: s.wcinc * kscale,
           incf: s.fprod >>> 24 &&& (1 <<< 64) - 1
         }}
      end)

    rows
  end

  defp cmds_gen do
    gen all kind <- StreamData.member_of([:manual, :follow]),
            rate <- StreamData.member_of(@rates),
            ppb <- StreamData.integer(-100_000..100_000),
            n <- StreamData.integer(150..300),
            big <- StreamData.integer(0..(1 <<< 58)) do
      inc = Nco.increment(rate, @clk, ppb)
      first = %{inc_wr: 1, inc_in: if(kind == :manual and rem(ppb, 3) == 0, do: big, else: inc)}

      first =
        if kind == :follow,
          do:
            Map.merge(first, %{
              winc_wr: 1,
              winc_in: Wallclock.increment(@nominal, ppb),
              follow: 1,
              kscale: MediaNco.kscale(rate)
            }),
          else: first

      cfg = if kind == :follow, do: %{follow: 1, kscale: MediaNco.kscale(rate)}, else: %{}
      [Map.merge(cfg, first) | List.duplicate(cfg, n)]
    end
  end

  property "accumulator, tick, rtp and mclk_en equal Nco.step cycle by cycle (manual and follow mode)" do
    check all(cmds <- cmds_gen(), max_runs: 30) do
      out = T.beam(@mod, stim(cmds)) |> Enum.drop(2)

      for {{e, o}, i} <- Enum.zip(model(cmds), out) |> Enum.with_index() do
        assert Map.take(o, [:phase, :rtp_ts, :tick, :mclk_en]) == e, "cycle #{i}"
      end
    end
  end

  test "256 mclk enables per sample, phase locked to the tick" do
    # one sample every 1024 cycles
    cmds = [%{inc_wr: 1, inc_in: 1 <<< 54}] ++ List.duplicate(%{}, 3500)
    out = T.beam(@mod, stim(cmds))
    ticks = for {o, i} <- Enum.with_index(out), o.tick == 1, do: i
    assert length(ticks) == 3
    assert Enum.zip(ticks, tl(ticks)) |> Enum.all?(fn {a, b} -> b - a == 1024 end)

    counts =
      for {a, b} <- Enum.zip(ticks, tl(ticks)),
          do: out |> Enum.slice((a + 1)..b) |> Enum.count(&(&1.mclk_en == 1))

    assert counts == [256, 256]
  end

  # -- alignment to the wallclock ---------------------------------------------------------------

  defp align_case do
    gen all rate <- StreamData.member_of(@rates),
            sec <- StreamData.integer(0..0xFFFFFFFFFFFF),
            ns <- StreamData.integer(0..999_999_999),
            ppb <- StreamData.integer(-50_000..50_000),
            offset <- StreamData.integer(0..0xFFFFFFFF),
            at <- StreamData.integer(8..40) do
      %{rate: rate, sec: sec, ns: ns, ppb: ppb, offset: offset, at: at}
    end
  end

  defp align_stim(c) do
    cfg = %{rate: c.rate, offset: c.offset, kscale: MediaNco.kscale(c.rate), follow: 1}

    ev =
      [
        %{
          set_wr: 1,
          set_sec: c.sec,
          set_ns: c.ns,
          winc_wr: 1,
          winc_in: Wallclock.increment(@nominal, c.ppb)
        }
      ] ++ List.duplicate(%{}, c.at) ++ [%{align: 1}] ++ List.duplicate(%{}, 220)

    stim(Enum.map(ev, &Map.merge(cfg, &1)))
  end

  # ideal minus hardware, signed, modulo 2^96
  defp err(o, c) do
    hw = o.rtp_ts <<< 64 ||| o.phase
    ideal = MediaNco.ideal({o.now_sec, o.now_ns, o.now_frac}, c.rate, c.offset)
    d = hw - ideal &&& (1 <<< 96) - 1
    if d >= 1 <<< 95, do: d - (1 <<< 96), else: d
  end

  defp check_aligned(c, out) do
    done = for {o, i} <- Enum.with_index(out), o.aligned == 1, do: i
    assert [at] = done
    busy = Enum.count(out, &(&1.busy == 1))
    assert busy in 80..100, "busy for #{busy} cycles"

    for {o, i} <- Enum.with_index(out), i >= at do
      # inc is quantised (about 1000 units of 2^-64 sample per cycle), counted from the capture
      cycles = i - (at - busy) + 1
      assert abs(err(o, c)) <= 2048 * cycles, "cycle #{i - at} after alignment: #{err(o, c)}"
    end

    at
  end

  property "after align, rtp and phase equal floor(t * rate) + offset and its fraction, any rate" do
    check all(c <- align_case(), max_runs: 20) do
      out = T.beam(@mod, align_stim(c))
      check_aligned(c, out)
    end
  end

  test "matches the MediaClock model (whole ns): the RTP timestamp of 1 s is the rate" do
    c = %{rate: 48_000, sec: 1, ns: 0, ppb: 0, offset: 77, at: 10}
    out = T.beam(@mod, align_stim(c))
    at = check_aligned(c, out)
    o = Enum.at(out, at)
    t = %Timestamp{seconds: o.now_sec, nanoseconds: o.now_ns}
    assert o.rtp_ts == MediaClock.rtp_timestamp(t, 48_000, 77)
    assert o.rtp_ts in 48_077..48_078
  end

  test "a second align after a wallclock step brings the media clock back in line" do
    c = %{rate: 48_000, sec: 10, ns: 5, ppb: 0, offset: 0, at: 10}
    cfg = %{rate: c.rate, offset: 0, kscale: MediaNco.kscale(c.rate), follow: 1}

    ev =
      [%{set_wr: 1, set_sec: 10, set_ns: 5}] ++
        List.duplicate(%{}, 10) ++
        [%{align: 1}] ++
        List.duplicate(%{}, 150) ++
        [%{set_wr: 1, set_sec: 500, set_ns: 123_456_789}] ++
        List.duplicate(%{}, 20) ++
        [%{align: 1}] ++ List.duplicate(%{}, 250)

    out = T.beam(@mod, stim(Enum.map(ev, &Map.merge(cfg, &1))))
    [a1, a2] = for {o, i} <- Enum.with_index(out), o.aligned == 1, do: i
    assert abs(err(Enum.at(out, a1 + 50), c)) < 1 <<< 18
    # before the second align the clock is off by the step ...
    assert abs(err(Enum.at(out, a2 - 5), c)) > 1 <<< 70
    # ... after it, in line again
    assert abs(err(Enum.at(out, a2 + 100), c)) <= 2048 * 200
  end

  @tag :verilator
  @tag timeout: 300_000
  property "Verilator equals the BEAM simulator (align and free running)" do
    check all(c <- align_case(), cmds <- cmds_gen(), max_runs: 3) do
      T.cosim(@mod, align_stim(c))
      T.cosim(@mod, stim(cmds))
    end
  end
end
