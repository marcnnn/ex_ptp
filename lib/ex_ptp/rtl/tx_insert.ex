defmodule ExPtp.RTL.TxInsert do
  @moduledoc """
  One-step Sync support on the transmit stream: overwrites the 10 byte
  `originTimestamp` of a Sync message with the wallclock time at which the
  frame starts to leave, and optionally zeroes the UDP checksum.

  The module sits in the TX stream right in front of the MAC TX (same clock
  as the wallclock; one register slice of latency, ready passes through
  combinationally). `now_sec`, `now_ns`, `now_frac` are the wallclock in the
  stream's clock domain: run the wallclock on the MAC TX clock, or put a
  wallclock copy there. Across clocks no exact insertion is possible.

  ## Timestamp

  The time is sampled when the first beat of a frame is accepted, plus
  `comp` (u32, 2^-16 ns): the fixed delay from this module's input to the
  first bit on the wire (preamble, MAC and PHY pipeline), calibrated once.
  The stream is `ExNet.RTL.Ifc.mac_tx/2`: `tuser` (the PTP tag) is passed on
  with every beat. From the first beat accepted here in cycle `a` to the Start
  word on the MAC's pins are `ExNet.RTL.Ifc.tx_first_beat_cycles/0` (2) cycles
  with `ExNet.RTL.MacTx` directly behind (`comp` covers them plus the PHY).
  It is computed in the cycles before the origin field arrives (at least
  6 beats later on a 64 bit bus, 48 on an 8 bit bus) and truncated to
  nanoseconds: `stamp/2` is the model. The MAC TX does not stall after it
  accepted the first beat (a bubble before the second beat is the MAC's
  idle cycle: `ready` passes through, nothing is lost); the source must not
  pause inside a frame (`ExNet.RTL.Ifc` says why: store and forward before
  this module).

  ## What is modified

  With `enable` high, in a PTP frame (`ExPtp.RTL.PtpDetect`: L2 or UDP,
  up to two VLAN tags) whose messageType is Sync (0): the 10 bytes at the
  PTP header offset + 34 become `seconds (6 bytes) nanoseconds (4 bytes)`,
  big endian. The twoStepFlag is the software's business (clear it in a
  one-step Sync). With `zero_csum` also high, in a UDP frame to port 319
  the checksum field becomes 0, which IPv4 defines as "no checksum".

  The decision is made from bytes earlier in the frame (destination port
  before the checksum, messageType 34 bytes before the origin field), so the
  data path needs no delay line.

  ## Checksum and FCS

  A correct nonzero UDP checksum is impossible without store and forward:
  the checksum precedes the changed bytes and depends on their old value,
  which is not seen yet. Zeroing (IPv4 only) or letting the MAC adjust the
  checksum at the end of the frame are the two options; IPv6 needs the MAC
  option. The Ethernet FCS is appended by the MAC TX after this module, so
  it covers the modified bytes without extra work. A frame that the MAC
  generates its FCS for must therefore not already carry one.

  `stamped` pulses at the last beat of every frame that was modified.
  """
  use ExHdl.RTL
  import Bitwise

  alias ExNet.RTL.Ifc, as: NetIfc
  alias ExPtp.RTL.PtpDetect

  @wrap 1_000_000_000 <<< 16

  @doc """
  `{sec, ns}` written for `{sec, ns, frac32}` and `comp` (2^-16 ns).

      iex> ExPtp.RTL.TxInsert.stamp({5, 999_999_999, 0}, 65536 * 3)
      {6, 2}
  """
  def stamp({sec, ns, frac}, comp) do
    t = (ns <<< 16 ||| frac >>> 16) + comp
    if t >= @wrap, do: {sec + 1, (t - @wrap) >>> 16}, else: {sec, t >>> 16}
  end

  @doc "The frame with the origin timestamp and checksum edits the hardware applies (a model)."
  def apply_model(frame, now, comp, enable, zero_csum) do
    info = PtpDetect.classify(frame)
    {sec, ns} = stamp(now, comp)
    ts = <<sec::48, ns::32>>

    frame
    |> then(
      &if enable and info.ptp and info.mtype == 0, do: patch(&1, info.ptp_off + 34, ts), else: &1
    )
    |> then(
      &if enable and zero_csum and info.ev_port,
        do: patch(&1, info.l4_off + 6, <<0, 0>>),
        else: &1
    )
  end

  defp patch(frame, at, _bytes) when byte_size(frame) <= at, do: frame

  defp patch(frame, at, bytes) do
    n = min(byte_size(bytes), byte_size(frame) - at)
    <<pre::binary-size(at), _::binary-size(n), post::binary>> = frame
    pre <> binary_part(bytes, 0, n) <> post
  end

  def build(bits \\ 64) do
    wb = div(bits, 8)
    lg = ExHdl.RTL.Builder.ceil_log2(wb)
    axis = NetIfc.mac_tx(bits, keep: true)

    module "ptp_tx_insert_w#{bits}" do
      s = slave(:s_axis, axis)
      m = master(:m_axis, axis)
      enable = input(:enable, 1)
      zero_csum = input(:zero_csum, 1)
      comp = input(:comp, 32)
      now_sec = input(:now_sec, 48)
      now_ns = input(:now_ns, 32)
      now_frac = input(:now_frac, 32)
      stamped = output(:stamped, 1, reset: 0)

      d = instance(:d, PtpDetect.build(bits, [:beat, :ptp, :mtype, :ptp_off, :ev_port, :l4_off]))

      o_valid = reg(:o_valid, 1)
      o_data = reg(:o_data, bits, reset: nil)
      o_keep = reg(:o_keep, wb, reset: nil)
      o_last = reg(:o_last, 1, reset: nil)
      o_user = reg(:o_user, 8, reset: nil)
      at_start = reg(:at_start, 1, reset: 1)
      did = reg(:did, 1)
      c_sec = reg(:c_sec, 48, reset: nil)
      c_ns = reg(:c_ns, 30, reset: nil)
      c_frac = reg(:c_frac, 16, reset: nil)
      ins_sec = reg(:ins_sec, 48, reset: nil)
      ins_ns = reg(:ins_ns, 30, reset: nil)

      room = wire(:room, not o_valid or m.tready)
      s.tready <~ room
      accept = wire(:accept, s.tvalid and room)
      d.valid <~ accept
      d.data <~ s.tdata
      d.keep <~ s.tkeep
      d.last <~ s.tlast

      # origin time + compensation, registered every cycle (stable well before it is used)
      sum = wire(:sum, cat([c_ns, c_frac]) + comp)
      carry = wire(:carry, sum >= @wrap)
      ns_sum = wire(:ns_sum, trunc(mux(carry, sum - @wrap, sum), 46))

      # the lane replacements
      sync_msg = wire(:sync_msg, enable and d.ptp and d.mtype == 0)
      zero_en = wire(:zero_en, enable and zero_csum and d.ev_port)
      base = wire(:base, trunc(zext(d.beat, 16) <<< lg, 16))
      o_start = wire(:o_start, add_wrap(zext(d.ptp_off, 16), 34))
      c_start = wire(:c_start, add_wrap(zext(d.l4_off, 16), 6))
      ts80 = wire(:ts80, cat([ins_sec, zext(ins_ns, 32)]))
      ts_bytes = for i <- 0..9, do: ts80[(72 - 8 * i)..(79 - 8 * i)]

      lanes =
        for j <- 0..(wb - 1) do
          pos = add_wrap(base, j)
          in_ts = pos >= o_start and pos < add_wrap(o_start, 10)
          k = trunc(sub_wrap(pos, o_start), 4)
          ts_byte = mux(k, ts_bytes ++ List.duplicate(const(0, u(8)), 6))
          in_cs = pos == c_start or pos == add_wrap(c_start, 1)
          orig = o_data[(8 * j)..(8 * j + 7)]

          %{
            byte: mux(sync_msg and in_ts, ts_byte, mux(zero_en and in_cs, const(0, u(8)), orig)),
            ts: sync_msg and in_ts,
            cs: zero_en and in_cs
          }
        end

      m.tvalid <~ o_valid
      m.tdata <~ cat(lanes |> Enum.map(& &1.byte) |> Enum.reverse())
      m.tkeep <~ o_keep
      m.tlast <~ o_last
      m.tuser <~ o_user
      hit = wire(:hit, Enum.reduce(lanes, false, fn l, acc -> acc or l.ts end))

      sync do
        ins_sec <~ add_wrap(c_sec, zext(carry, 48))
        ins_ns <~ ns_sum[16..45]
        stamped <~ 0
        if m.tready, do: o_valid <~ 0

        if accept do
          o_valid <~ 1
          o_data <~ s.tdata
          o_keep <~ s.tkeep
          o_last <~ s.tlast
          o_user <~ s.tuser
          at_start <~ s.tlast

          if at_start do
            c_sec <~ now_sec
            c_ns <~ now_ns[0..29]
            c_frac <~ now_frac[16..31]
          end
        end

        if o_valid and m.tready do
          if hit, do: did <~ 1

          if o_last do
            stamped <~ (did or hit)
            did <~ 0
          end
        end
      end
    end
  end
end
