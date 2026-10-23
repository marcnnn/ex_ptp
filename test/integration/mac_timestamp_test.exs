defmodule ExPtp.Integration.MacTimestampTest do
  @moduledoc """
  Timestamps through the real MAC (ex_net) and the timestamp unit: MAC TX `tx_sof` and
  `tx_tag`, MAC RX `rx_sof`, on a MAC clock unrelated to the wallclock's.
  """
  use ExUnit.Case, async: true
  import Bitwise

  alias ExNet.MAC.{Rx64, Tx64}
  alias ExPtp.RTL.{Meta, TimestampUnit}
  alias ExPtp.Test.{Loop, MacBench}

  @moduletag timeout: 300_000

  # 0.1 ns units: sys 8 ns, MAC 6.4 ns
  @clocks [sys: [period: 80, phase: 3], mac: [period: 64, phase: 17]]
  @p_sys 8.0
  @p_mac 6.4
  @resets 6

  defp total_ns({s, n, f}), do: s * 1_000_000_000 + n + f / 65536

  # a wallclock that tracks the event time: `now - t/10` is constant (one sys period per tick)
  defp clock_offset(events) do
    {t, o} =
      events
      |> Enum.filter(&(:clk in &1.fire))
      |> List.last()
      |> then(&{&1.t, &1.outs})

    o.now_sec * 1_000_000_000 + o.now_ns - t / 10
  end

  defp frame(len, seed) do
    :binary.list_to_bin(for i <- 1..len, do: rem(i * 31 + seed * 17, 251))
  end

  defp resets(i),
    do: %{rst_n: if(i < @resets, do: 0, else: 1), rst_mac_n: if(i < @resets, do: 0, else: 1)}

  # -- TX ------------------------------------------------------------------------------------

  defp tx_run(frames) do
    mod = MacBench.stamp_bench()
    comp = TimestampUnit.nominal_comp(:tx, @p_mac, @p_sys)
    beats = Enum.map(frames, &Tx64.beats/1)
    n = length(frames) * 120 + 400

    init = %{
      todo: beats,
      cur: nil,
      wait: 20,
      tags: Enum.to_list(1..length(frames)),
      tag: nil,
      pop: 0
    }

    res =
      Loop.run(
        mod,
        n,
        init,
        fn st, ev ->
          base = Map.merge(resets(ev.i), %{tx_comp: comp, rx_comp: 0})

          if :clk_mac in ev.fire and ev.i >= @resets do
            mac_side(st, ev, base)
          else
            sys_side(st, ev, base)
          end
        end,
        clocks: @clocks
      )

    {mod, res}
  end

  # one MAC event: start a frame when idle for `wait` events, offer the head beat; the MAC takes
  # it at this edge if its `tready` is high now (it does not depend on our inputs)
  defp mac_side(st, ev, base) do
    st =
      cond do
        st.cur == nil and st.wait > 0 ->
          %{st | wait: st.wait - 1}

        st.cur == nil and st.todo != [] ->
          [h | t] = st.todo
          [tag | tags] = st.tags
          %{st | cur: %{beats: h, n: 0}, todo: t, tags: tags, tag: tag}

        true ->
          st
      end

    case st.cur do
      nil ->
        {Map.merge(base, %{s_axis_tvalid: 0, tx_pop: 0}), st}

      %{beats: [{d, k, l} | rest], n: n} = cur ->
        taken = ev.outs.s_axis_tready == 1

        st =
          cond do
            not taken -> st
            l -> %{st | cur: nil, wait: 20}
            true -> %{st | cur: %{cur | beats: rest, n: n + 1}}
          end

        {Map.merge(base, %{
           s_axis_tvalid: 1,
           s_axis_tdata: d,
           s_axis_tkeep: k,
           s_axis_tlast: if(l, do: 1, else: 0),
           s_axis_tuser: if(n == 0, do: st.tag, else: 0),
           tx_pop: 0
         }), st}
    end
  end

  defp sys_side(st, ev, base) do
    pop = if :clk in ev.fire and ev.outs.tx_ts_valid == 1 and st.pop == 0, do: 1, else: 0
    st = if :clk in ev.fire, do: %{st | pop: pop}, else: st
    {Map.merge(base, %{tx_pop: pop}), st}
  end

  test "TX: the stamp of every frame is the wallclock at the SFD within half a system period; tags match" do
    frames = for i <- 1..8, do: frame(60 + 13 * i, i)
    {_mod, res} = tx_run(frames)
    ev = res.events
    c = clock_offset(ev)

    sofs = for e <- ev, :clk_mac in e.fire, e.outs.mac_tx_sof == 1, do: {e.t, e.outs.mac_tx_tag}
    assert length(sofs) == length(frames)
    assert Enum.map(sofs, &elem(&1, 1)) == Enum.to_list(1..length(frames))

    # the frames on the pins are what was sent, no error words
    words =
      for e <- ev,
          :clk_mac in e.fire,
          e.outs.xgmii_txc != 0xFF or e.outs.xgmii_txd != 0x0707070707070707,
          do: {e.outs.xgmii_txd, e.outs.xgmii_txc}

    got = Rx64.frames(words)
    assert Enum.all?(got, &match?({:ok, _}, &1))
    assert Enum.map(got, &elem(&1, 1)) == Enum.map(frames, &pad60/1)

    # timestamps popped from the FIFO: the head is valid at a sys event and popped there
    stamps =
      for e <- ev, :clk in e.fire, e.inputs.tx_pop == 1, e.outs.tx_ts_valid == 1 do
        {e.outs.tx_ts_tag, total_ns(Meta.unpack_ts(e.outs.tx_ts))}
      end

    assert Enum.map(stamps, &elem(&1, 0)) == Enum.to_list(1..length(frames))

    errs =
      for {{t, tag}, {tag2, ts}} <- Enum.zip(sofs, stamps) do
        assert tag == tag2
        ts - (t / 10 + c)
      end

    IO.puts(
      "MAC TX stamp error vs wallclock at the SFD edge: #{Float.round(Enum.min(errs), 2)}..#{Float.round(Enum.max(errs), 2)} ns (sys period #{@p_sys} ns)"
    )

    assert Enum.all?(errs, &(abs(&1) <= 0.6 * @p_sys))
    assert Enum.all?(ev, &(&1.outs.tx_overflow == 0))
  end

  defp pad60(f) when byte_size(f) < 60, do: f <> :binary.copy(<<0>>, 60 - byte_size(f))
  defp pad60(f), do: f

  # -- RX ------------------------------------------------------------------------------------

  test "RX: the stamp of every received frame is the wallclock at the edge sampling the Start word" do
    mod = MacBench.stamp_bench()
    comp = TimestampUnit.nominal_comp(:rx, @p_mac, @p_sys)
    frames = for i <- 1..8, do: frame(60 + 29 * i, i + 3)
    idle = {0x0707070707070707, 0xFF}

    words =
      List.duplicate(idle, 12) ++
        Enum.flat_map(Tx64.run(frames), fn w -> [w] end) ++ List.duplicate(idle, 40)

    # the words of Tx64.run start with the model's own idle; find the Start words (lane 0 /S/)
    starts = for {{d, c}, i} <- Enum.with_index(words), c == 0x01 and (d &&& 0xFF) == 0xFB, do: i
    assert length(starts) == length(frames)

    res =
      Loop.run(
        mod,
        2 * length(words) + 100,
        0,
        fn k, ev ->
          base = Map.merge(resets(ev.i), %{rx_comp: comp, tx_comp: 0, tx_pop: 0})

          if :clk_mac in ev.fire and ev.i >= @resets do
            # the k-th MAC event after reset applies word k
            {w, c} = Enum.at(words, k, idle)
            {Map.merge(base, %{xgmii_rxd: w, xgmii_rxc: c}), k + 1}
          else
            {base, k}
          end
        end,
        clocks: @clocks
      )

    ev = res.events
    c = clock_offset(ev)

    mac_events = for {e, i} <- Enum.with_index(ev), :clk_mac in e.fire and i >= @resets, do: e
    wire = for s <- starts, do: Enum.at(mac_events, s).t

    seen =
      for e <- ev,
          :clk in e.fire,
          e.outs.rx_valid == 1,
          do: total_ns(Meta.unpack_ts(e.outs.rx_ts))

    assert length(seen) == length(frames)
    errs = for {t, ts} <- Enum.zip(wire, seen), do: ts - (t / 10 + c)

    IO.puts(
      "MAC RX stamp error vs wallclock at the Start word edge: #{Float.round(Enum.min(errs), 2)}..#{Float.round(Enum.max(errs), 2)} ns"
    )

    assert Enum.all?(errs, &(abs(&1) <= 0.6 * @p_sys))

    # the frames also come out of the MAC, in order, one `rx_sof` each
    assert Enum.count(ev, &(:clk_mac in &1.fire and &1.outs.mac_rx_sof == 1)) == length(frames)
  end

  @tag :verilator
  test "Verilator equals the BEAM simulator on the TX run (two clocks)" do
    {mod, res} = tx_run(for i <- 1..3, do: frame(70 + 9 * i, i))
    ExHdl.RTL.Cosim.assert_equivalent(mod, res.stim, clocks: @clocks)
  end
end
