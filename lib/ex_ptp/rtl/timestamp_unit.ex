defmodule ExPtp.RTL.TimestampUnit do
  @moduledoc """
  Hardware timestamp unit: latches the wallclock when the MAC announces a
  start-of-frame delimiter, for RX and TX, with the clock domain crossing
  from the MAC clock (125 or 156.25 MHz) to the system clock the wallclock
  runs on.

  Domains: `:mac` (`clk_mac`, `rst_mac_n`) and `:sys` (`clk`, `rst_n`).

  ## MAC side (domain `:mac`)

  `rx_sof` and `tx_sof` are one-cycle strobes at the SFD of a received and a
  transmitted frame (the interface the ex_net MAC provides). `tx_tag`
  (`tag_bits`, default 8) is the software's per-frame tag and must be valid
  during the `tx_sof` cycle. Consecutive SOFs of one kind must be at least
  8 `:mac` cycles apart (84 byte times: always true on Ethernet).

  ## System side (domain `:sys`)

  `now_sec`, `now_ns`, `now_frac` come from `ExPtp.RTL.Wallclock`.
  `rx_comp` / `tx_comp` (u32, 2^-16 ns) are subtracted from the captured
  time: the fixed latency between the SFD at the PHY or MAC and the capture,
  measured once per board.

  Outputs, all in `:sys`:

    * `rx_valid` (one cycle), `rx_ts` (`ExPtp.RTL.Meta`: 94 bits)
    * `tx_ts_valid` (a TX timestamp is waiting), `tx_ts_tag`, `tx_ts` (head
      of a 4 entry FIFO), `tx_pop` removes it, `tx_overflow` (one cycle)
      reports a dropped one.

  ## Timing

  The SOF strobe crosses with `ExHdl.RTL.CDC.pulse_sync/1` (toggle, two
  flip-flops, edge detect), the tag as a held register that is stable for
  at least 8 `:mac` cycles after the strobe and sampled only after the
  pulse arrived (`cdc: true`; give the tag path a max-delay constraint, no
  synchroniser). The capture cycle is 3 to 4 `:sys` cycles after the SOF
  depending on the clock phase: the timestamp is uncertain by one `:sys`
  period (8 ns at 125 MHz, 4 ns at 250 MHz). Set `*_comp` to the mean
  latency (about 3.5 periods plus the MAC and PHY pipeline). With the
  wallclock on the MAC clock itself no crossing is needed and the
  uncertainty is zero; use `capture:` inputs of the wallclock then.

  `compensate/2` is the arithmetic as an Elixir model.

  ## Reference point and nominal compensation

  The stamp is meant to be the wallclock at the Start word on the wire: for RX the MAC clock
  edge that samples the Start word on the pins (`ExNet.RTL.MacRx.rx_sof` follows
  `ExNet.RTL.Ifc.rx_sof_cycles/0` cycle later), for TX the edge at which the PHY samples the
  Start word (`tx_sof` is high in that Start word's cycle, offset
  `ExNet.RTL.Ifc.tx_sof_cycles/0`). `nominal_comp/3` is the compensation for that:
  the `:sys` capture latency (mean 2.5 periods, 2 to 3) plus the MAC's strobe offset.
  The remaining error is the capture jitter, at most half a `:sys` period either way,
  plus the PHY and gearbox delay of a real board (add it to the nominal value).
  """
  use ExHdl.RTL
  import Bitwise

  alias ExHdl.RTL.CDC
  alias ExNet.RTL.Ifc, as: NetIfc

  @ns 1_000_000_000
  @wrap @ns <<< 16

  @doc """
  `{sec, ns, frac32}` minus `comp` (2^-16 ns) as `{sec, ns, frac16}`; the
  fraction is truncated to 16 bits first, below the epoch it clamps to zero.

      iex> ExPtp.RTL.TimestampUnit.compensate({5, 10, 0x80000000}, 65536 * 12)
      {4, 999_999_998, 32768}
  """
  def compensate({sec, ns, frac}, comp) do
    t = (ns <<< 16 ||| frac >>> 16) - comp

    cond do
      t >= 0 -> {sec, t >>> 16, t &&& 0xFFFF}
      sec == 0 -> {0, 0, 0}
      true -> {sec - 1, (t + @wrap) >>> 16, t + @wrap &&& 0xFFFF}
    end
  end

  @doc """
  Nominal `rx_comp` / `tx_comp` (u32, 2^-16 ns) for MAC and system clock periods in ns:
  the mean capture latency of the clock domain crossing, 2.5 `:sys` periods, plus for
  RX the MAC cycles `rx_sof` trails the pins (`ExNet.RTL.Ifc.rx_sof_cycles/0`, 1) and for
  TX `ExNet.RTL.Ifc.tx_sof_cycles/0` (0). Measured: the stamp equals the wallclock at the edge
  that samples the Start word within +-0.5 `:sys` periods (`test/integration/mac_timestamp_test.exs`).

      iex> Float.round(ExPtp.RTL.TimestampUnit.nominal_comp(:tx, 6.4, 8.0) / 65536, 3)
      20.0
      iex> Float.round(ExPtp.RTL.TimestampUnit.nominal_comp(:rx, 6.4, 8.0) / 65536, 3)
      26.4
  """
  def nominal_comp(side, mac_period_ns, sys_period_ns) when side in [:rx, :tx] do
    cycles = if side == :rx, do: NetIfc.rx_sof_cycles(), else: NetIfc.tx_sof_cycles()
    round((2.5 * sys_period_ns + cycles * mac_period_ns) * 65536)
  end

  def build(opts \\ []) do
    tag = Keyword.get(opts, :tag_bits, 8)

    module "ptp_timestamp_unit_t#{tag}" do
      domain(:mac, clock: :clk_mac, reset: :rst_mac_n)
      domain(:sys)
      rx = slave(:rx, NetIfc.ts_rx(), domain: :mac)
      tx = slave(:tx, NetIfc.ts_tx(tag), domain: :mac)
      rx_sof = rx.sof
      tx_sof = tx.sof
      tx_tag = tx.tag
      now_sec = input(:now_sec, 48, domain: :sys)
      now_ns = input(:now_ns, 32, domain: :sys)
      now_frac = input(:now_frac, 32, domain: :sys)
      rx_comp = input(:rx_comp, 32, domain: :sys)
      tx_comp = input(:tx_comp, 32, domain: :sys)
      tx_pop = input(:tx_pop, 1, domain: :sys)

      rx_valid = output(:rx_valid, 1)
      rx_ts = output(:rx_ts, 94)
      tx_ts_valid = output(:tx_ts_valid, 1)
      tx_ts_tag = output(:tx_ts_tag, tag)
      tx_ts = output(:tx_ts, 94)
      tx_overflow = output(:tx_overflow, 1)

      rx_p = instance(:rx_sync, CDC.pulse_sync(), domains: [src: :mac, dst: :sys])
      tx_p = instance(:tx_sync, CDC.pulse_sync(), domains: [src: :mac, dst: :sys])
      rx_p.pulse_in <~ rx_sof
      tx_p.pulse_in <~ tx_sof

      tag_hold = reg(:tag_hold, tag, domain: :mac)

      sync :mac do
        if tx_sof, do: tag_hold <~ tx_tag
      end

      # stage 1: the wallclock at the cycle the pulse is seen
      rx_v = reg(:rx_v, 1, domain: :sys)
      tx_v = reg(:tx_v, 1, domain: :sys)
      c_sec = for k <- [:rx, :tx], do: reg(:"#{k}_sec", 48, domain: :sys)
      c_ns = for k <- [:rx, :tx], do: reg(:"#{k}_ns", 30, domain: :sys)
      c_frac = for k <- [:rx, :tx], do: reg(:"#{k}_frac", 16, domain: :sys)
      c_tag = reg(:c_tag, tag, domain: :sys, cdc: true)

      sync :sys do
        rx_v <~ rx_p.pulse_out
        tx_v <~ tx_p.pulse_out

        for {p, i} <- [{rx_p.pulse_out, 0}, {tx_p.pulse_out, 1}] do
          if p do
            Enum.at(c_sec, i) <~ now_sec
            Enum.at(c_ns, i) <~ now_ns[0..29]
            Enum.at(c_frac, i) <~ now_frac[16..31]
          end
        end

        if tx_p.pulse_out, do: c_tag <~ tag_hold
      end

      # stage 2: compensation, combinational from the stage 1 registers
      stamp = fn i, comp ->
        t = cat([Enum.at(c_ns, i), Enum.at(c_frac, i)])
        diff = to_signed(t) - to_signed(comp)
        neg = diff < 0
        wrapped = trunc(as_unsigned(diff + @wrap), 46)
        plain = trunc(as_unsigned(diff), 46)
        sec = Enum.at(c_sec, i)
        zero = sec == 0
        value = mux(neg, wrapped, plain)
        s = mux(neg, sub_wrap(sec, 1), sec)
        cat([mux(neg and zero, 0, s), mux(neg and zero, 0, value)])
      end

      rx_valid <~ rx_v
      rx_ts <~ stamp.(0, rx_comp)

      fifo = instance(:txq, ExPtp.RTL.TsFifo.build(94 + tag, 2, status: false))
      fifo.push <~ tx_v
      fifo.din <~ cat([c_tag, stamp.(1, tx_comp)])
      fifo.pop <~ tx_pop
      tx_ts_valid <~ not fifo.empty
      tx_ts_tag <~ fifo.dout[94..(94 + tag - 1)]
      tx_ts <~ fifo.dout[0..93]
      tx_overflow <~ fifo.overflow
    end
  end
end
