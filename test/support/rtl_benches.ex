defmodule ExPtp.Test.Benches do
  @moduledoc false
  use ExHdl.RTL
  alias ExPtp.RTL.{TimestampUnit, Wallclock}

  @doc "Wallclock and timestamp unit with two clocks; the wallclock is only settable."
  def ts_bench do
    module "ts_bench" do
      domain(:mac, clock: :clk_mac, reset: :rst_mac_n)
      domain(:sys)
      rx_sof = input(:rx_sof, 1, domain: :mac)
      tx_sof = input(:tx_sof, 1, domain: :mac)
      tx_tag = input(:tx_tag, 8, domain: :mac)
      rx_comp = input(:rx_comp, 32, domain: :sys)
      tx_comp = input(:tx_comp, 32, domain: :sys)
      tx_pop = input(:tx_pop, 1, domain: :sys)

      now =
        for n <- [:now_sec, :now_ns, :now_frac],
            do: output(n, if(n == :now_sec, do: 48, else: 32))

      rx_valid = output(:rx_valid, 1)
      rx_ts = output(:rx_ts, 94)
      tx_ts_valid = output(:tx_ts_valid, 1)
      tx_ts_tag = output(:tx_ts_tag, 8)
      tx_ts = output(:tx_ts, 94)
      tx_overflow = output(:tx_overflow, 1)
      slew_busy = output(:slew_busy, 1)

      wc = instance(:wc, Wallclock.build(ncap: 0, snap: false, pps: false))
      for p <- ~w(inc_wr set_wr step_wr slew_wr)a, do: wc[p] <~ 0

      for {p, w} <- [
            inc_in: 40,
            set_sec: 48,
            set_ns: 30,
            slew_r: 32,
            slew_ticks: 32
          ],
          do: wc[p] <~ const(0, u(w))

      wc.step_ns <~ const(0, s(30))
      wc.slew_q <~ const(0, s(64))

      u =
        instance(:u, TimestampUnit.build(),
          connect: [
            rx_sof: rx_sof,
            tx_sof: tx_sof,
            tx_tag: tx_tag,
            now_sec: wc.now_sec,
            now_ns: wc.now_ns,
            now_frac: wc.now_frac,
            rx_comp: rx_comp,
            tx_comp: tx_comp,
            tx_pop: tx_pop
          ]
        )

      [now_sec, now_ns, now_frac] = now
      now_sec <~ wc.now_sec
      now_ns <~ wc.now_ns
      now_frac <~ wc.now_frac
      rx_valid <~ u.rx_valid
      rx_ts <~ u.rx_ts
      tx_ts_valid <~ u.tx_ts_valid
      tx_ts_tag <~ u.tx_ts_tag
      tx_ts <~ u.tx_ts
      tx_overflow <~ u.tx_overflow
      slew_busy <~ wc.slew_busy
    end
  end

  @doc "A passthrough stream with `PtpDetect` tapped on it; the detector outputs are bench outputs."
  def detect_bench(bits) do
    axis = Interface.axi_stream(data: bits)

    module "detect_bench_w#{bits}" do
      s = slave(:s_axis, axis)
      m = master(:m_axis, axis)
      connect(s, m)
      d = instance(:d, ExPtp.RTL.PtpDetect.build(bits))
      d.valid <~ (s.tvalid and m.tready)
      d.data <~ s.tdata
      d.keep <~ s.tkeep
      d.last <~ s.tlast

      for {n, w} <- [beat: 8, ptp: 1, udp: 1, mtype: 4, ptp_off: 6, ev_port: 1, l4_off: 6] do
        output(n, w) <~ d[n]
      end
    end
  end

  @doc "A free-running wallclock feeding `TxInsert`; the time is settable and observable."
  def tx_bench(bits) do
    axis = ExNet.RTL.Ifc.mac_tx(bits, keep: true)

    module "tx_bench_w#{bits}" do
      s = slave(:s_axis, axis)
      m = master(:m_axis, axis)
      enable = input(:enable, 1)
      zero_csum = input(:zero_csum, 1)
      comp = input(:comp, 32)
      set_wr = input(:set_wr, 1)
      set_sec = input(:set_sec, 48)
      set_ns = input(:set_ns, 30)
      now_sec = output(:now_sec, 48)
      now_ns = output(:now_ns, 32)
      now_frac = output(:now_frac, 32)
      stamped = output(:stamped, 1)
      busy = output(:slew_busy, 1)

      wc = instance(:wc, Wallclock.build(ncap: 0, snap: false, pps: false))
      wc.set_wr <~ set_wr
      wc.set_sec <~ set_sec
      wc.set_ns <~ set_ns
      for p <- ~w(inc_wr step_wr slew_wr)a, do: wc[p] <~ 0

      for {p, w} <- [inc_in: 40, slew_r: 32, slew_ticks: 32], do: wc[p] <~ const(0, u(w))

      wc.step_ns <~ const(0, s(30))
      wc.slew_q <~ const(0, s(64))

      u =
        instance(:u, ExPtp.RTL.TxInsert.build(bits),
          connect: [
            enable: enable,
            zero_csum: zero_csum,
            comp: comp,
            now_sec: wc.now_sec,
            now_ns: wc.now_ns,
            now_frac: wc.now_frac
          ]
        )

      connect(s, u.s_axis)
      connect(u.m_axis, m)
      now_sec <~ wc.now_sec
      now_ns <~ wc.now_ns
      now_frac <~ wc.now_frac
      stamped <~ u.stamped
      busy <~ wc.slew_busy
    end
  end

  @doc "A wallclock (settable, increment writable) feeding the media NCO."
  def media_bench do
    module "media_bench" do
      ins =
        for {n, w} <- [
              set_sec: 48,
              set_ns: 30,
              winc_in: 40,
              rate: 18,
              offset: 32,
              inc_in: 64,
              kscale: 56
            ],
            into: %{},
            do: {n, input(n, w)}

      flags =
        for n <- [:set_wr, :winc_wr, :inc_wr, :follow, :align], into: %{}, do: {n, input(n, 1)}

      outs =
        for {n, w} <- [
              now_sec: 48,
              now_ns: 32,
              now_frac: 32,
              tick: 1,
              mclk_en: 1,
              rtp_ts: 32,
              phase: 64,
              busy: 1,
              aligned: 1
            ],
            into: %{},
            do: {n, output(n, w)}

      slew_busy = output(:slew_busy, 1)

      wc = instance(:wc, Wallclock.build(ncap: 0, snap: false, pps: false, inc_out: true))
      wc.set_wr <~ flags.set_wr
      wc.set_sec <~ ins.set_sec
      wc.set_ns <~ ins.set_ns
      wc.inc_wr <~ flags.winc_wr
      wc.inc_in <~ ins.winc_in
      for p <- ~w(step_wr slew_wr)a, do: wc[p] <~ 0
      for {p, w} <- [slew_r: 32, slew_ticks: 32], do: wc[p] <~ const(0, u(w))
      wc.step_ns <~ const(0, s(30))
      wc.slew_q <~ const(0, s(64))

      u =
        instance(:u, ExPtp.RTL.MediaNco.build(),
          connect: [
            now_sec: wc.now_sec,
            now_ns: wc.now_ns,
            now_frac: wc.now_frac,
            rate: ins.rate,
            offset: ins.offset,
            inc_wr: flags.inc_wr,
            inc_in: ins.inc_in,
            follow: flags.follow,
            wc_inc: wc.inc_out,
            kscale: ins.kscale,
            align: flags.align
          ]
        )

      outs.now_sec <~ wc.now_sec
      outs.now_ns <~ wc.now_ns
      outs.now_frac <~ wc.now_frac
      slew_busy <~ wc.slew_busy
      for n <- [:tick, :mclk_en, :rtp_ts, :phase, :busy, :aligned], do: outs[n] <~ u[n]
    end
  end
end
