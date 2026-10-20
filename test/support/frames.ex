defmodule ExPtp.Test.Frames do
  @moduledoc false
  use ExUnitProperties
  import StreamData
  alias ExPtp.{Message, Timestamp}

  @src {<<1, 2, 3, 4, 5, 6, 7, 8>>, 1}

  def ptp_payload(type, seq, ts \\ Timestamp.new(0, 0)) do
    case type do
      :follow_up ->
        Message.encode(Message.new(:follow_up, @src, seq, %{precise_origin_timestamp: ts}))

      # not a real Announce body; only the messageType nibble matters to the hardware
      :announce ->
        <<_, rest::binary>> = ptp_payload(:sync, seq, ts)
        <<0x0B, rest::binary>>

      t ->
        Message.encode(Message.new(t, @src, seq, %{origin_timestamp: ts}))
    end
  end

  def vlan(tags) do
    for t <- tags, into: <<>>, do: <<t::16, 0x0001::16>>
  end

  def eth(dst, tags, ethertype, payload, pad \\ 60) do
    frame =
      <<dst::binary, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0x01, vlan(tags)::binary, ethertype::16>> <>
        payload

    pad(frame, pad)
  end

  def pad(frame, n) when byte_size(frame) < n,
    do: frame <> :binary.copy(<<0>>, n - byte_size(frame))

  def pad(frame, _), do: frame

  def udp(dport, payload, csum \\ 0xBEEF, ihl_words \\ 5) do
    len = 8 + byte_size(payload)
    opts = :binary.copy(<<0>>, (ihl_words - 5) * 4)

    ip =
      <<4::4, ihl_words::4, 0, ihl_words * 4 + len::16, 0x1234::16, 0::16, 64, 17, 0::16, 10, 0,
        0, 1, 224, 0, 1, 129>>

    ip <> opts <> <<0x13F::16, dport::16, len::16, csum::16>> <> payload
  end

  @l2_dst <<1, 0x1B, 0x19, 0, 0, 0>>
  @ip_dst <<1, 0, 0x5E, 0, 1, 129>>

  def l2(type, tags, seq, ts \\ Timestamp.new(0, 0)),
    do: eth(@l2_dst, tags, 0x88F7, ptp_payload(type, seq, ts))

  def over_udp(type, tags, seq, ts \\ Timestamp.new(0, 0)) do
    port = if type in [:follow_up, :announce], do: 320, else: 319
    eth(@ip_dst, tags, 0x0800, udp(port, ptp_payload(type, seq, ts)))
  end

  @types [:sync, :delay_req, :follow_up, :announce, :pdelay_req]
  @tpids [0x8100, 0x88A8]

  @doc "`{frame, truth}`; truth is what a correct detector reports (`:none` or `{type, :l2 | :udp}`)."
  def frame_gen do
    tags = list_of(member_of(@tpids), max_length: 2)
    type = member_of(@types)
    seq = integer(0..0xFFFF)

    frequency([
      {5, gen(all t <- type, g <- tags, s <- seq, do: {l2(t, g, s), {t, :l2}})},
      {5, gen(all t <- type, g <- tags, s <- seq, do: {over_udp(t, g, s), {t, :udp}})},
      {1, gen(all g <- list_of(member_of(@tpids), length: 3), do: {l2(:sync, g, 1), :none})},
      {1,
       gen all g <- tags, port <- member_of([1234, 318, 321, 0x13F0]) do
         {eth(@ip_dst, g, 0x0800, udp(port, ptp_payload(:sync, 1))), :none}
       end},
      {1,
       gen all g <- tags do
         {eth(@ip_dst, g, 0x0800, udp(319, ptp_payload(:sync, 1), 0xBEEF, 6)), :none}
       end},
      {1,
       gen all g <- tags,
               et <- member_of([0x0806, 0x86DD, 0x88F8, 0x0801]),
               b <- binary(length: 50) do
         {eth(@l2_dst, g, et, b), :none}
       end},
      {1,
       gen all f <- member_of([l2(:sync, [], 1), over_udp(:sync, [], 1)]), n <- integer(1..45) do
         {binary_part(f, 0, n), :runt}
       end},
      {1, gen(all b <- binary(min_length: 1, max_length: 120), do: {b, :none})}
    ])
  end

  @doc "Truth for a frame built by this module, from `frame_gen/0`, as the detector's fields."
  def truth(:none), do: %{ptp: false, udp: false}

  def truth({t, kind}),
    do: %{
      ptp: true,
      udp: kind == :udp,
      mtype: Map.fetch!(%{sync: 0, delay_req: 1, pdelay_req: 2, follow_up: 8, announce: 11}, t)
    }

  def bytes(frame), do: for(<<b <- frame>>, do: b)
end
