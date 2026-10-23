defmodule ExPtp.RTL.Ifc do
  @moduledoc """
  The interfaces ex_ptp produces or consumes, defined once (the MAC side is
  `ExNet.RTL.Ifc`).

  ## Media clock: `media_clock/2` (producer `ExPtp.RTL.MediaNco`, consumers `ExAes67.RTL.JitterBuffer`, `Packetiser`, `Rx`)

  Two flat ports in the consumer's clock domain:

    * `tick` (1): one cycle per sample period, in the same cycle in which `rtp_ts`
      changes. Ticks are at least `channels + 16` cycles apart for the jitter buffer.
    * `rtp_ts` (32): the media time of the sample period that starts with the tick
      (`floor(t * rate) + offset` modulo 2^32, `ExPtp.MediaClock.rtp_timestamp/3`),
      stable until the next tick. After a wallclock step and `align` it jumps; the
      consumers then see a step in time, not a tick.

  A wallclock on another clock needs a CDC (`ExHdl.RTL.CDC.pulse_sync/1` for `tick`, a
  held register sampled after it for `rtp_ts`) in front of the consumer.

  ## Timestamps

  `ExPtp.RTL.Meta` has the 94 bit timestamp and the 102 bit `tuser` of `RxStamp`
  (`{bad, mtype(4), udp, ptp, ts_valid, ts(94)}`, valid on the last beat). The strobes
  come from `ExNet.RTL.Ifc.ts_rx/0` and `ts_tx/1`; `ExPtp.RTL.TimestampUnit.nominal_comp/3`
  gives the compensation that makes a stamp equal the wallclock at the SFD on the wire.
  """
  alias ExHdl.RTL.Builder

  @doc """
  Declares the media clock ports in the module being built and returns
  `%{tick: handle, rtp_ts: handle}`. `role` is `:master` (outputs) or `:slave` (inputs);
  `opts` go to the port declarations (`reset: 0` for registered outputs, `domain:`).
  """
  def media_clock(role, opts \\ []) when role in [:master, :slave] do
    port = if role == :master, do: &Builder.output/3, else: &Builder.input/3
    %{tick: port.(:tick, {:u, 1}, opts), rtp_ts: port.(:rtp_ts, {:u, 32}, opts)}
  end

  @doc "Width of `rtp_ts`."
  def rtp_ts_bits, do: 32
end
