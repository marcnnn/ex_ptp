defmodule ExPtp.Test.MacBench do
  @moduledoc false
  use ExHdl.RTL
  alias ExNet.RTL.{Ifc, MacRx, MacTx}
  alias ExPtp.RTL.{TimestampUnit, TxInsert, Wallclock}

  @doc """
  MAC TX and MAC RX (64 bit) on the `:mac` clock, wallclock and `TimestampUnit` on `:sys`
  (two unrelated clocks). The MAC strobes feed the unit; the XGMII pins and the stream of
  the receiver are exposed.
  """
  def stamp_bench do
    module "mac_stamp_bench" do
      domain(:mac, clock: :clk_mac, reset: :rst_mac_n)
      domain(:sys)

      s = slave(:s_axis, Ifc.mac_tx(64), domain: :mac)
      rxd = input(:xgmii_rxd, 64, domain: :mac)
      rxc = input(:xgmii_rxc, 8, domain: :mac)
      rx_comp = input(:rx_comp, 32, domain: :sys)
      tx_comp = input(:tx_comp, 32, domain: :sys)
      tx_pop = input(:tx_pop, 1, domain: :sys)

      txd = output(:xgmii_txd, 64, domain: :mac)
      txc = output(:xgmii_txc, 8, domain: :mac)
      mtx_sof = output(:mac_tx_sof, 1, domain: :mac)
      mtx_tag = output(:mac_tx_tag, 8, domain: :mac)
      mrx_sof = output(:mac_rx_sof, 1, domain: :mac)
      m = master(:m_axis, Ifc.mac_rx(64), domain: :mac)
      fend = output(:frame_end, 1, domain: :mac)
      status = output(:status, 3, domain: :mac)

      now_sec = output(:now_sec, 48)
      now_ns = output(:now_ns, 32)
      now_frac = output(:now_frac, 32)
      rx_valid = output(:rx_valid, 1)
      rx_ts = output(:rx_ts, 94)
      tx_ts_valid = output(:tx_ts_valid, 1)
      tx_ts_tag = output(:tx_ts_tag, 8)
      tx_ts = output(:tx_ts, 94)
      tx_overflow = output(:tx_overflow, 1)

      mtx = instance(:mtx, MacTx.build(64), domains: [sys: :mac])

      mrx =
        instance(:mrx, MacRx.build(64),
          domains: [sys: :mac],
          connect: [xgmii_rxd: rxd, xgmii_rxc: rxc]
        )

      connect(s, mtx.s_axis)
      connect(mrx.m_axis, m)

      wc = instance(:wc, Wallclock.build(ncap: 0, snap: false, pps: false))
      for p <- ~w(inc_wr set_wr step_wr slew_wr)a, do: wc[p] <~ 0

      for {p, w} <- [inc_in: 40, set_sec: 48, set_ns: 30, slew_r: 32, slew_ticks: 32],
          do: wc[p] <~ const(0, u(w))

      wc.step_ns <~ const(0, s(30))
      wc.slew_q <~ const(0, s(64))

      u =
        instance(:u, TimestampUnit.build(),
          connect: [
            rx_sof: mrx.rx_sof,
            tx_sof: mtx.tx_sof,
            tx_tag: mtx.tx_tag,
            now_sec: wc.now_sec,
            now_ns: wc.now_ns,
            now_frac: wc.now_frac,
            rx_comp: rx_comp,
            tx_comp: tx_comp,
            tx_pop: tx_pop
          ]
        )

      txd <~ mtx.xgmii_txd
      txc <~ mtx.xgmii_txc
      mtx_sof <~ mtx.tx_sof
      mtx_tag <~ mtx.tx_tag
      mrx_sof <~ mrx.rx_sof
      fend <~ mrx.frame_end
      status <~ mrx.status
      now_sec <~ wc.now_sec
      now_ns <~ wc.now_ns
      now_frac <~ wc.now_frac
      rx_valid <~ u.rx_valid
      rx_ts <~ u.rx_ts
      tx_ts_valid <~ u.tx_ts_valid
      tx_ts_tag <~ u.tx_ts_tag
      tx_ts <~ u.tx_ts
      tx_overflow <~ u.tx_overflow
    end
  end

  @doc """
  One clock: wallclock, `TxInsert` and MAC TX (64 bit), `period_ns` per cycle. The
  wallclock is settable (`set_*`), the XGMII pins and the MAC strobes are exposed.
  """
  def one_step_bench(period_ns) do
    inc = round(period_ns * 4_294_967_296)

    module "mac_one_step_bench" do
      s = slave(:s_axis, Ifc.mac_tx(64))
      enable = input(:enable, 1)
      zero_csum = input(:zero_csum, 1)
      comp = input(:comp, 32)
      set_wr = input(:set_wr, 1)
      set_sec = input(:set_sec, 48)
      set_ns = input(:set_ns, 30)

      txd = output(:xgmii_txd, 64)
      txc = output(:xgmii_txc, 8)
      sof = output(:tx_sof, 1)
      tag = output(:tx_tag, 8)
      stamped = output(:stamped, 1)
      now_sec = output(:now_sec, 48)
      now_ns = output(:now_ns, 32)
      now_frac = output(:now_frac, 32)

      wc = instance(:wc, Wallclock.build(ncap: 0, snap: false, pps: false, nominal: inc))
      wc.set_wr <~ set_wr
      wc.set_sec <~ set_sec
      wc.set_ns <~ set_ns
      for p <- ~w(inc_wr step_wr slew_wr)a, do: wc[p] <~ 0
      for {p, w} <- [inc_in: 40, slew_r: 32, slew_ticks: 32], do: wc[p] <~ const(0, u(w))
      wc.step_ns <~ const(0, s(30))
      wc.slew_q <~ const(0, s(64))

      ins =
        instance(:ins, TxInsert.build(64),
          connect: [
            enable: enable,
            zero_csum: zero_csum,
            comp: comp,
            now_sec: wc.now_sec,
            now_ns: wc.now_ns,
            now_frac: wc.now_frac
          ]
        )

      mac = instance(:mac, MacTx.build(64))
      connect(s, ins.s_axis)
      connect(ins.m_axis, mac.s_axis)

      txd <~ mac.xgmii_txd
      txc <~ mac.xgmii_txc
      sof <~ mac.tx_sof
      tag <~ mac.tx_tag
      stamped <~ ins.stamped
      now_sec <~ wc.now_sec
      now_ns <~ wc.now_ns
      now_frac <~ wc.now_frac
    end
  end
end
