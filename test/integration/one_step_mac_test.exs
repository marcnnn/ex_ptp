defmodule ExPtp.Integration.OneStepMacTest do
  @moduledoc """
  One-step Sync through `TxInsert` and the real MAC TX (ex_net) on one clock with the wallclock:
  the origin timestamp written into the frame equals the wallclock at the edge that samples
  the Start word on the wire, the UDP checksum is zero, the FCS (appended by the MAC after the
  insertion) is valid, and other frames pass unchanged.
  """
  use ExUnit.Case, async: true
  import Bitwise

  alias ExNet.{Ethernet, IPv4, UDP}
  alias ExNet.MAC.Rx64
  alias ExNet.RTL.Ifc
  alias ExPtp.{Message, Timestamp}
  alias ExPtp.RTL.TxInsert
  alias ExPtp.Test.{Loop, MacBench}

  @moduletag timeout: 300_000
  @period 6.4
  @src_ip {10, 0, 0, 1}
  @ptp_ip {224, 0, 1, 129}
  @clock_id <<1, 2, 3, 4, 5, 6, 7, 8>>

  defp ptp_frame(type, seq, port, opts \\ []) do
    ts = Keyword.get(opts, :ts, Timestamp.new(0, 0))
    key = if type == :follow_up, do: :precise_origin_timestamp, else: :origin_timestamp
    msg = Message.new(type, {@clock_id, 1}, seq, %{key => ts})

    udp =
      UDP.encode(
        %UDP{src_port: port, dst_port: port, payload: Message.encode(msg)},
        @src_ip,
        @ptp_ip
      )

    ip =
      IPv4.encode(%IPv4{src: @src_ip, dst: @ptp_ip, protocol: 17, ttl: 1, id: seq, payload: udp})

    Ethernet.encode(%Ethernet{
      dst: Ethernet.multicast_mac(@ptp_ip),
      src: <<2, 0, 0, 0, 0, 0x42>>,
      tags: Keyword.get(opts, :tags, []),
      ethertype: 0x0800,
      payload: ip
    })
  end

  defp beats(frame) do
    chunks = for <<c::binary-size(8) <- frame>>, do: c
    rest = binary_part(frame, 8 * length(chunks), byte_size(frame) - 8 * length(chunks))
    all = chunks ++ if(rest == <<>>, do: [], else: [rest])

    for {c, i} <- Enum.with_index(all, 1) do
      bits = 8 * byte_size(c)
      <<v::little-size(bits)>> = c
      {v, (1 <<< byte_size(c)) - 1, i == length(all)}
    end
  end

  defp run(frames, comp, opts \\ []) do
    mod = MacBench.one_step_bench(@period)
    n = length(frames) * 90 + 200
    init = %{todo: Enum.map(frames, &beats/1), cur: nil, wait: 5, accepts: []}

    Loop.run(
      mod,
      n,
      init,
      fn st, ev ->
        base = %{
          enable: 1,
          zero_csum: Keyword.get(opts, :zero, 1),
          comp: comp,
          set_wr: if(ev.i == 2, do: 1, else: 0),
          set_sec: 1000,
          set_ns: 999_999_900,
          rst_n: if(ev.i < 2, do: 0, else: 1)
        }

        st =
          if st.cur == nil and st.wait == 0 and st.todo != [] do
            [h | t] = st.todo
            %{st | cur: h, todo: t}
          else
            if st.cur == nil and st.wait > 0, do: %{st | wait: st.wait - 1}, else: st
          end

        case st.cur do
          nil ->
            {Map.put(base, :s_axis_tvalid, 0), st}

          [{d, k, l} | rest] ->
            taken = ev.outs.s_axis_tready == 1
            first = ev.i
            st = if taken, do: %{st | accepts: [first | st.accepts]}, else: st

            st =
              cond do
                not taken -> st
                l -> %{st | cur: nil, wait: 12}
                true -> %{st | cur: rest}
              end

            {Map.merge(base, %{
               s_axis_tvalid: 1,
               s_axis_tdata: d,
               s_axis_tkeep: k,
               s_axis_tlast: if(l, do: 1, else: 0),
               s_axis_tuser: 0
             }), st}
        end
      end
    )
  end

  defp total({s, n, f}), do: s * 1_000_000_000 + n + f / 4_294_967_296

  test "the origin timestamp is the wallclock at the SFD edge; checksum zero; FCS valid" do
    k = Ifc.tx_first_beat_cycles()
    comp = round(k * @period * 65536)

    frames = [
      ptp_frame(:sync, 1, 319),
      ptp_frame(:sync, 2, 319,
        tags: [%{tpid: 0x88A8, pcp: 0, dei: 0, vid: 5}, %{tpid: 0x8100, pcp: 0, dei: 0, vid: 6}]
      ),
      ptp_frame(:delay_req, 3, 319),
      ptp_frame(:follow_up, 4, 320),
      ptp_frame(:sync, 5, 319),
      ptp_frame(:sync, 6, 319)
    ]

    res = run(frames, comp)
    ev = res.events

    # the SOF (the edge that samples the Start word) is `tx_first_beat_cycles` events after the
    # event in which TxInsert accepted the first beat
    accepts = MapSet.new(res.state.accepts)
    sofs = for {e, i} <- Enum.with_index(ev), e.outs.tx_sof == 1, do: i
    assert length(sofs) == length(frames)
    assert Enum.all?(sofs, &MapSet.member?(accepts, &1 - k)), "k = #{k}"

    words =
      for e <- ev,
          e.outs.xgmii_txc != 0xFF or e.outs.xgmii_txd != 0x0707070707070707,
          do: {e.outs.xgmii_txd, e.outs.xgmii_txc}

    out = Rx64.frames(words)

    assert Enum.all?(out, &match?({:ok, _}, &1)),
           "FCS and framing: #{inspect(Enum.map(out, &elem(&1, 0)))}"

    assert length(out) == length(frames)

    for {{{:ok, got}, sent}, sof} <-
          Enum.zip(Enum.zip(out, frames) |> Enum.map(fn {{_, b}, s} -> {{:ok, b}, s} end), sofs) do
      {:ok, eth} = Ethernet.decode(got)
      {:ok, ip} = IPv4.decode(eth.payload)
      {:ok, udp} = UDP.decode(ip.payload)
      {:ok, msg} = Message.decode(udp.payload)
      {:ok, sent_eth} = Ethernet.decode(sent)
      {:ok, sent_ip} = IPv4.decode(sent_eth.payload)
      {:ok, sent_udp} = UDP.decode(sent_ip.payload)
      {:ok, sent_msg} = Message.decode(sent_udp.payload)

      if msg.type == :sync do
        # wallclock at the SFD edge: the value shown at the SOF event
        o = Enum.at(ev, sof).outs
        wire = total({o.now_sec, o.now_ns, o.now_frac})
        ts = msg.body.origin_timestamp
        written = ts.seconds * 1_000_000_000 + ts.nanoseconds
        assert written <= wire and wire - written < 1.0, "#{written} vs #{wire}"
        # UDP checksum field zero on the wire, the rest of the message untouched
        <<_::binary-size(6), csum::16, _::binary>> = ip.payload
        assert csum == 0
        assert %{msg | body: %{}} == %{sent_msg | body: %{}}
        assert ip.ttl == sent_ip.ttl and ip.id == sent_ip.id
      else
        # event port frames get the zero checksum, everything else is untouched
        want =
          if udp.dst_port == 319 do
            <<a::binary-size(40), _::16, b::binary>> = sent
            <<a::binary, 0::16, b::binary>>
          else
            sent
          end

        assert got == want
      end
    end

    # the insertion model agrees: stamp/2 of the wallclock at the accept event
    {sec, ns} = TxInsert.stamp({1000, 999_999_900, 0}, 0)
    assert {sec, ns} == {1000, 999_999_900}
    assert Enum.all?(ev, &(&1.outs.stamped in [0, 1]))
    assert Enum.count(ev, &(&1.outs.stamped == 1)) == 4
  end

  @tag :verilator
  test "Verilator equals the BEAM simulator" do
    frames = [ptp_frame(:sync, 1, 319), ptp_frame(:delay_req, 2, 319)]
    res = run(frames, 3 * 6 * 65536)
    mod = MacBench.one_step_bench(@period)
    ExHdl.RTL.Cosim.assert_equivalent(mod, res.stim)
  end
end
