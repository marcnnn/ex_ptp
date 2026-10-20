defmodule ExPtp.RTL.Meta do
  @moduledoc """
  Bit layouts shared by the timestamping RTL and software.

  A hardware timestamp is 94 bits: `{seconds::48, nanoseconds::30,
  fraction::16}`, the fraction in 2^-16 ns like the correctionField.

  `m_axis_tuser` of `ExPtp.RTL.RxStamp` (valid on the last beat) is 102 bits:

  | Bits | Field |
  |---|---|
  | 93:0 | RX timestamp |
  | 94 | timestamp valid |
  | 95 | PTP message (EtherType 0x88F7 or UDP 319/320) |
  | 96 | transported over UDP (else L2) |
  | 100:97 | messageType |
  | 101 | bad frame (the MAC's tuser on the last beat) |
  """
  import Bitwise

  @ts_bits 94
  @tuser_bits 102

  def ts_bits, do: @ts_bits
  def tuser_bits, do: @tuser_bits

  @doc "Packs seconds, nanoseconds and 2^-16 ns fraction."
  def pack_ts({sec, ns, frac}), do: sec <<< 46 ||| ns <<< 16 ||| frac

  @doc "Inverse of `pack_ts/1`."
  def unpack_ts(v), do: {v >>> 46, v >>> 16 &&& 0x3FFFFFFF, v &&& 0xFFFF}

  @doc "A packed timestamp as `ExPtp.Timestamp` (fraction dropped)."
  def to_timestamp(v) do
    {s, n, _} = unpack_ts(v)
    %ExPtp.Timestamp{seconds: s, nanoseconds: n}
  end

  defp bit(u, i), do: (u >>> i &&& 1) == 1

  @doc "Unpacks the RX `tuser`."
  def unpack_tuser(u) do
    %{
      ts: u &&& (1 <<< @ts_bits) - 1,
      ts_valid: bit(u, 94),
      ptp: bit(u, 95),
      udp: bit(u, 96),
      message_type: u >>> 97 &&& 0xF,
      bad: bit(u, 101)
    }
  end

  @doc "Packs an RX `tuser` (inverse of `unpack_tuser/1`)."
  def pack_tuser(m) do
    b = fn k -> if m[k], do: 1, else: 0 end

    m.ts ||| b.(:ts_valid) <<< 94 ||| b.(:ptp) <<< 95 ||| b.(:udp) <<< 96 |||
      (m.message_type &&& 0xF) <<< 97 ||| b.(:bad) <<< 101
  end
end
