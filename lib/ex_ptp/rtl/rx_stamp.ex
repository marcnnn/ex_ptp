defmodule ExPtp.RTL.RxStamp do
  @moduledoc """
  Receive side of the timestamp path: attaches the hardware timestamp and
  the PTP classification to every frame as `tuser` metadata
  (`ExPtp.RTL.Meta`, 102 bits, valid on the last beat; one register slice of
  latency, no extra beats).

  Clock domain: everything in `:sys`. `s_axis` is the stream after the MAC
  and its CDC FIFO, `ts_valid`/`ts` come from `ExPtp.RTL.TimestampUnit`
  (`rx_valid`, `rx_ts`).

  ## Contract with the MAC

  Every `rx_sof` of the timestamp unit is followed by exactly one frame on
  `s_axis`, in order (bad frames included, flagged with bit 0 of the 4 bit
  `s_axis_tuser` on their last beat, `ExNet.RTL.Ifc.mac_rx/2`; they are not
  dropped between the SOF and this module). The stream is the MAC receive
  stream, or its classifier output (`ExNet.RTL.Classifier`, which keeps the
  frames and adds 14 cycles; connect its `tdata`, `tkeep`, `tlast`, `tuser`,
  `tvalid`). Timestamps are queued (4 entries); the first beat of a frame
  waits until its timestamp is there. The timestamp unit has a latency of
  about 3 `:sys` cycles after the SOF and the stream normally arrives
  later (the MAC's first beat 2 cycles after `rx_sof`, the classifier 14
  more), so the wait is zero. `s_axis_tready` is then high whenever the sink is
  ready: behind a source that cannot stall (MAC, classifier) keep `m_axis_tready`
  high or put a FIFO behind this module. After `wait` cycles (default 127) the frame
  goes out with `ts_valid = 0` (`no_ts` pulses) and the timestamp that
  arrives late is discarded, so the queue never loses its alignment.
  `ts_overflow` pulses when a timestamp found the queue full.

  `PtpDetect` runs as a passive tap on the accepted beats, so the PTP
  flags are known from the beat holding the messageType byte on (byte 14 of
  an L2 frame up to byte 50 over UDP with two tags). The `tuser` of earlier
  beats is incomplete; read it on the last beat.
  """
  use ExHdl.RTL

  alias ExNet.RTL.Ifc, as: NetIfc
  alias ExPtp.RTL.{PtpDetect, TsFifo}

  def build(bits \\ 64, opts \\ []) do
    wait = Keyword.get(opts, :wait, 127)
    s_if = NetIfc.mac_rx(bits, ready: true, keep: true)
    m_if = Interface.axi_stream(data: bits, user: 102)

    module "ptp_rx_stamp_w#{bits}_t#{wait}" do
      s = slave(:s_axis, s_if)
      m = master(:m_axis, m_if)
      ts_valid = input(:ts_valid, 1)
      ts = input(:ts, 94)
      no_ts = output(:no_ts, 1, reset: 0)
      ts_overflow = output(:ts_overflow, 1)

      q = instance(:q, TsFifo.build(94, 2, status: false))
      d = instance(:d, PtpDetect.build(bits, [:ptp, :udp, :mtype]))

      o_valid = reg(:o_valid, 1)
      o_data = reg(:o_data, bits, reset: nil)
      o_keep = reg(:o_keep, div(bits, 8), reset: nil)
      o_last = reg(:o_last, 1, reset: nil)
      o_bad = reg(:o_bad, 1, reset: nil)
      ts_r = reg(:ts_r, 94, reset: nil)
      ts_ok = reg(:ts_ok, 1)
      at_start = reg(:at_start, 1, reset: 1)
      wcnt = reg(:wcnt, 8)
      skip = reg(:skip, 4)

      have = wire(:have, not q.empty and skip == 0)
      discard = wire(:discard, skip != 0 and not q.empty)
      room = wire(:room, not o_valid or m.tready)
      go = wire(:go, not at_start or have or wcnt == wait)
      s.tready <~ (room and go)
      accept = wire(:accept, s.tvalid and room and go)
      late = wire(:late, accept and at_start and not have)

      q.push <~ ts_valid
      q.din <~ ts
      q.pop <~ (discard or (accept and at_start and have))
      ts_overflow <~ q.overflow
      d.valid <~ accept
      d.data <~ s.tdata
      d.keep <~ s.tkeep
      d.last <~ s.tlast

      sync do
        no_ts <~ late

        if m.tready, do: o_valid <~ 0

        if accept do
          o_valid <~ 1
          o_data <~ s.tdata
          o_keep <~ s.tkeep
          o_last <~ s.tlast
          o_bad <~ NetIfc.bad(s.tuser)
          at_start <~ s.tlast

          if at_start do
            ts_r <~ q.dout
            ts_ok <~ have
          end
        end

        if accept do
          wcnt <~ 0
        else
          if s.tvalid and at_start and room and not go, do: wcnt <~ add_wrap(wcnt, 1)
        end

        # a frame went out without a timestamp: the next one to arrive is its own
        if late and not discard, do: skip <~ mux(skip == 15, skip, add_wrap(skip, 1))
        if discard and not late, do: skip <~ sub_wrap(skip, 1)
      end

      m.tvalid <~ o_valid
      m.tdata <~ o_data
      m.tkeep <~ o_keep
      m.tlast <~ o_last
      m.tuser <~ cat([o_bad, d.mtype, d.udp, d.ptp, ts_ok, ts_r])
    end
  end
end
