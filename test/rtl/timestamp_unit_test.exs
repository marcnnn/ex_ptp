defmodule ExPtp.RTL.TimestampUnitTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Bitwise

  alias ExHdl.RTL.Sim
  alias ExPtp.RTL.{Meta, TimestampUnit}
  alias ExPtp.Test.Benches
  alias ExPtp.Test.RTL, as: T

  @mod Benches.ts_bench()
  # 0.1 ns units: sys 8 ns, MAC 6.4 ns (156.25 MHz)
  @clocks [sys: [period: 80, phase: 3], mac: [period: 64, phase: 17]]
  @resets 12

  doctest TimestampUnit

  # Events with SOFs: on the MAC edge events, `rx` and `tx` choose frames at random gaps (in MAC
  # cycles, at least 8 apart per kind).
  defp stimulus(rx_gaps, tx_gaps, n, comp) do
    events = Sim.schedule(@mod, n, clocks: @clocks)
    base = T.idle(@mod)

    {stim, _} =
      Enum.map_reduce(Enum.with_index(events), {rx_gaps, tx_gaps, 12, 12, 0, 0}, fn
        {{_t, fire}, i}, {rg, tg, rwait, twait, tag, sysn} ->
          mac? = :clk_mac in fire
          sys? = :clk in fire
          {rx, rg, rwait} = frame(mac?, i > @resets, rg, rwait)
          {tx, tg, twait} = frame(mac?, i > @resets, tg, twait)
          tag = if tx == 1, do: tag + 1, else: tag
          pop = if sys? and rem(sysn, 5) == 0, do: 1, else: 0

          ev = %{
            rx_sof: rx,
            tx_sof: tx,
            tx_tag: tag &&& 255,
            tx_pop: pop,
            rx_comp: comp,
            tx_comp: comp,
            rst_n: if(i < @resets, do: 0, else: 1),
            rst_mac_n: if(i < @resets, do: 0, else: 1)
          }

          {Map.merge(base, ev), {rg, tg, rwait, twait, tag, if(sys?, do: sysn + 1, else: sysn)}}
      end)

    {events, stim}
  end

  defp frame(false, _, gaps, wait), do: {0, gaps, wait}
  defp frame(true, false, gaps, wait), do: {0, gaps, wait}
  defp frame(true, true, gaps, 0), do: {1, tl_or(gaps), hd_or(gaps)}
  defp frame(true, true, gaps, wait), do: {0, gaps, wait - 1}
  defp tl_or([_ | t]), do: t
  defp tl_or([]), do: []
  defp hd_or([h | _]), do: h
  defp hd_or([]), do: 1_000_000

  defp gaps, do: StreamData.list_of(StreamData.integer(8..40), length: 60)

  defp run(rx, tx, n, comp) do
    {events, stim} = stimulus(rx, tx, n, comp)
    out = T.beam(@mod, stim, clocks: @clocks)
    {events, stim, out}
  end

  defp total_ns({s, n, f}), do: s * 1_000_000_000 + n + f / 65536

  property "RX timestamps are the compensated wallclock at the capture edge, one per SOF" do
    check all(rx <- gaps(), tx <- gaps(), comp <- StreamData.integer(0..(1 <<< 20)), max_runs: 6) do
      {events, stim, out} = run(rx, tx, 1500, comp)
      sys = for {{_, f}, i} <- Enum.with_index(events), :clk in f, do: i

      # now at every sys edge, the capture one edge later
      checked =
        for {i, j} <- Enum.zip(Enum.drop(sys, 1), sys),
            out |> Enum.at(i) |> Map.fetch!(:rx_valid) == 1,
            reduce: 0 do
          n ->
            o = Enum.at(out, j)
            exp = TimestampUnit.compensate({o.now_sec, o.now_ns, o.now_frac}, comp)
            assert Meta.unpack_ts(Enum.at(out, i).rx_ts) == exp
            n + 1
        end

      sofs = for {{_, f}, s} <- Enum.zip(events, stim), :clk_mac in f, s.rx_sof == 1, do: 1
      assert checked >= length(sofs) - 1 and checked <= length(sofs)
    end
  end

  test "capture latency is 1 to 5 system cycles after the SOF; TX tags come out in order" do
    rx = Enum.map(1..60, &(9 + rem(&1 * 5, 7)))
    tx = Enum.map(1..60, &(8 + rem(&1 * 7, 13)))
    {events, stim, out} = run(rx, tx, 2400, 0)

    # wallclock reading minus true time (ns) is constant: now advances 8 ns per 8 ns sys period
    c =
      for({{t, f}, o} <- Enum.zip(events, out), :clk in f, do: o.now_ns - t / 10)
      |> List.last()

    # SOF times and the timestamps seen on rx_valid (true time = 0.1 ns units / 10)
    sofs = for {{t, f}, s} <- Enum.zip(events, stim), :clk_mac in f, s.rx_sof == 1, do: t / 10 + c

    seen = for {{_, f}, o} <- Enum.zip(events, out), :clk in f, o.rx_valid == 1, do: o.rx_ts

    stamps = seen |> Enum.map(&total_ns(Meta.unpack_ts(&1)))
    assert length(stamps) >= length(sofs) - 2

    lat = for {s, t} <- Enum.zip(sofs, stamps), do: t - s
    assert Enum.all?(lat, &(&1 > 8 and &1 < 48)), inspect(Enum.take(lat, 8))

    IO.puts(
      "timestamp unit: latency #{Float.round(Enum.min(lat), 1)}..#{Float.round(Enum.max(lat), 1)} ns after the SOF (comp 0, 8 ns sys period)"
    )

    # TX: pop at sys edges where the FIFO head is valid
    tx_sofs =
      for {{t, f}, s} <- Enum.zip(events, stim),
          :clk_mac in f,
          s.tx_sof == 1,
          do: {s.tx_tag, t / 10 + c}

    got =
      for {{{_, f}, s}, o} <- Enum.zip(Enum.zip(events, stim), out),
          :clk in f and s.tx_pop == 1 and o.tx_ts_valid == 1,
          do: {o.tx_ts_tag, total_ns(Meta.unpack_ts(o.tx_ts))}

    assert length(got) >= length(tx_sofs) - 2
    assert Enum.map(got, &elem(&1, 0)) == Enum.take(Enum.map(tx_sofs, &elem(&1, 0)), length(got))

    for {{_, t}, {_, ts}} <- Enum.zip(tx_sofs, got),
        do: assert(ts - t > 8 and ts - t < 56)

    assert Enum.all?(out, &(&1.tx_overflow == 0))
  end

  test "compensation borrows from the seconds and clamps at the epoch" do
    assert TimestampUnit.compensate({3, 5, 0}, 10 * 65536) == {2, 999_999_995, 0}
    assert TimestampUnit.compensate({0, 5, 0}, 10 * 65536) == {0, 0, 0}
    assert TimestampUnit.compensate({3, 5, 0xFFFF0000}, 0) == {3, 5, 0xFFFF}
  end

  @tag :verilator
  @tag timeout: 300_000
  property "Verilator equals the BEAM simulator (two clocks)" do
    check all(rx <- gaps(), tx <- gaps(), comp <- StreamData.integer(0..(1 <<< 20)), max_runs: 3) do
      {_, stim} = stimulus(rx, tx, 1500, comp)
      T.cosim(@mod, stim, clocks: @clocks)
    end
  end
end
