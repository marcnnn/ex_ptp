defmodule ExPtp.Message do
  @moduledoc """
  IEEE 1588-2019 message codec (clause 13): the 34-byte common header and
  the bodies of Sync, Delay_Req, Follow_Up, Delay_Resp, Pdelay_Req,
  Pdelay_Resp, Pdelay_Resp_Follow_Up, Announce, Signaling and Management.
  Trailing TLVs are kept as `ExPtp.TLV` structs; Management bodies are the
  header fields plus TLV passthrough.

  Identities are `{clock_identity :: <<_::64>>, port_number}`. Timestamps are
  `ExPtp.Timestamp`, `correction` is in scaled ns (`ExPtp.Correction`).
  `decode/1` returns `{:error, reason}` for anything malformed and never
  raises; bytes beyond `messageLength` (Ethernet padding) are ignored.

      iex> alias ExPtp.{Message, Timestamp}
      iex> src = {<<1, 2, 3, 4, 5, 6, 7, 8>>, 1}
      iex> msg = Message.new(:sync, src, 7, %{origin_timestamp: Timestamp.new(5, 6)})
      iex> bin = Message.encode(msg)
      iex> byte_size(bin)
      44
      iex> {:ok, ^msg} = Message.decode(bin)
      iex> Message.decode(binary_part(bin, 0, 30))
      {:error, :short}
  """
  alias ExPtp.{Correction, Timestamp, TLV}
  import Bitwise

  defstruct major_sdo_id: 0,
            type: nil,
            minor_version: 0,
            version: 2,
            domain: 0,
            minor_sdo_id: 0,
            flags: 0,
            correction: 0,
            type_specific: 0,
            source: nil,
            sequence_id: 0,
            log_interval: 0x7F,
            body: %{},
            tlvs: []

  @type identity :: {<<_::64>>, 0..0xFFFF}
  @type t :: %__MODULE__{}

  @types %{
    0x0 => :sync,
    0x1 => :delay_req,
    0x2 => :pdelay_req,
    0x3 => :pdelay_resp,
    0x8 => :follow_up,
    0x9 => :delay_resp,
    0xA => :pdelay_resp_follow_up,
    0xB => :announce,
    0xC => :signaling,
    0xD => :management
  }
  @codes Map.new(@types, fn {k, v} -> {v, k} end)

  @flags [
    alternate_master: 0x0100,
    two_step: 0x0200,
    unicast: 0x0400,
    profile_specific_1: 0x2000,
    profile_specific_2: 0x4000,
    leap61: 0x0001,
    leap59: 0x0002,
    current_utc_offset_valid: 0x0004,
    ptp_timescale: 0x0008,
    time_traceable: 0x0010,
    frequency_traceable: 0x0020,
    synchronization_uncertain: 0x0040
  ]

  @doc "Message type codes, `%{0 => :sync, ...}`."
  def types, do: @types

  @doc """
  A message of `type` from `source` with `body` (maps as decoded by
  `decode/1`). Other header fields via `opts` (`:domain`, `:flags`,
  `:correction`, `:log_interval`, `:tlvs`, ...); `log_interval` defaults to
  0x7F, "not applicable".
  """
  def new(type, source, sequence_id, body \\ %{}, opts \\ []) do
    struct!(
      %__MODULE__{type: type, source: source, sequence_id: sequence_id, body: body},
      opts
    )
  end

  @doc "True if the named flag (see `flag_names/0`) is set in the flagField."
  def flag?(%__MODULE__{flags: flags}, name), do: (flags &&& Keyword.fetch!(@flags, name)) != 0

  @doc "Flag field from a list of flag names."
  def flags(names), do: Enum.reduce(names, 0, &(&2 ||| Keyword.fetch!(@flags, &1)))

  @doc "Names of the flags set in a flagField."
  def flag_names(flags) when is_integer(flags),
    do: for({n, bit} <- @flags, (flags &&& bit) != 0, do: n)

  @doc "Total message length in bytes of an encoded message."
  def length_of(%__MODULE__{} = m), do: 34 + byte_size(encode_body(m)) + tlv_size(m.tlvs)

  defp tlv_size(tlvs), do: tlvs |> TLV.encode_all() |> byte_size()

  # -- encoding ------------------------------------------------------------------------------

  @doc "Wire encoding; `messageLength` and `controlField` are derived."
  def encode(%__MODULE__{type: type, source: {cid, port}} = m) do
    body = encode_body(m)
    tlvs = TLV.encode_all(m.tlvs)
    len = 34 + byte_size(body) + byte_size(tlvs)

    <<m.major_sdo_id::4, Map.fetch!(@codes, type)::4, m.minor_version::4, m.version::4, len::16,
      m.domain::8, m.minor_sdo_id::8, m.flags::16, Correction.encode(m.correction)::binary,
      m.type_specific::32, cid::binary-8, port::16, m.sequence_id::16, control(type)::8,
      m.log_interval::signed-8, body::binary, tlvs::binary>>
  end

  defp control(:sync), do: 0
  defp control(:delay_req), do: 1
  defp control(:follow_up), do: 2
  defp control(:delay_resp), do: 3
  defp control(:management), do: 4
  defp control(_), do: 5

  defp pid({cid, port}), do: <<cid::binary-8, port::16>>
  defp ts(t), do: Timestamp.encode(t)

  defp encode_body(%{type: t, body: b}) when t in [:sync, :delay_req, :follow_up] do
    ts(b[:origin_timestamp] || b[:precise_origin_timestamp] || %Timestamp{})
  end

  defp encode_body(%{type: :pdelay_req, body: b}),
    do: <<ts(b.origin_timestamp)::binary, 0::80>>

  defp encode_body(%{type: :delay_resp, body: b}),
    do: <<ts(b.receive_timestamp)::binary, pid(b.requesting_port)::binary>>

  defp encode_body(%{type: :pdelay_resp, body: b}),
    do: <<ts(b.request_receipt_timestamp)::binary, pid(b.requesting_port)::binary>>

  defp encode_body(%{type: :pdelay_resp_follow_up, body: b}),
    do: <<ts(b.response_origin_timestamp)::binary, pid(b.requesting_port)::binary>>

  defp encode_body(%{type: :announce, body: b}) do
    <<ts(b.origin_timestamp)::binary, b.current_utc_offset::signed-16, 0::8, b.priority1::8,
      b.clock_class::8, b.clock_accuracy::8, b.offset_scaled_log_variance::16, b.priority2::8,
      b.grandmaster_identity::binary-8, b.steps_removed::16, b.time_source::8>>
  end

  defp encode_body(%{type: :signaling, body: b}), do: pid(b.target_port)

  defp encode_body(%{type: :management, body: b}) do
    <<pid(b.target_port)::binary, b.starting_boundary_hops::8, b.boundary_hops::8, 0::4,
      b.action::4, 0::8>>
  end

  # -- decoding ------------------------------------------------------------------------------

  @doc """
  Decodes a PTP message. Errors: `:short`, `{:unknown_type, n}`,
  `:bad_length`, `:bad_timestamp`, `:bad_tlv`, `:bad_body`.
  """
  def decode(bin) when is_binary(bin) do
    case bin do
      <<sdo::4, type::4, minor::4, version::4, len::16, domain::8, minor_sdo::8, flags::16,
        corr::binary-8, specific::32, cid::binary-8, port::16, seq::16, _control::8,
        log::signed-8, _::binary>> ->
        with {:ok, type} <- Map.fetch(@types, type) |> or_error({:unknown_type, type}),
             :ok <- check_length(len, bin),
             <<_::binary-34, rest::binary-size(len - 34), _::binary>> = bin,
             {:ok, body, tlvs} <- decode_body(type, rest),
             {:ok, tlvs} <- TLV.decode_all(tlvs) do
          {:ok,
           %__MODULE__{
             major_sdo_id: sdo,
             type: type,
             minor_version: minor,
             version: version,
             domain: domain,
             minor_sdo_id: minor_sdo,
             flags: flags,
             correction: Correction.decode(corr),
             type_specific: specific,
             source: {cid, port},
             sequence_id: seq,
             log_interval: log,
             body: body,
             tlvs: tlvs
           }}
        end

      _ ->
        {:error, :short}
    end
  end

  def decode(_), do: {:error, :short}

  defp or_error({:ok, v}, _), do: {:ok, v}
  defp or_error(:error, e), do: {:error, e}

  defp check_length(len, bin) when len < 34 or len > byte_size(bin),
    do: if(byte_size(bin) < 34, do: {:error, :short}, else: {:error, :bad_length})

  defp check_length(_, _), do: :ok

  defp decode_body(t, <<o::binary-10, rest::binary>>) when t in [:sync, :delay_req] do
    with {:ok, o} <- Timestamp.decode(o), do: {:ok, %{origin_timestamp: o}, rest}
  end

  defp decode_body(:follow_up, <<o::binary-10, rest::binary>>) do
    with {:ok, o} <- Timestamp.decode(o), do: {:ok, %{precise_origin_timestamp: o}, rest}
  end

  defp decode_body(:pdelay_req, <<o::binary-10, _::binary-10, rest::binary>>) do
    with {:ok, o} <- Timestamp.decode(o), do: {:ok, %{origin_timestamp: o}, rest}
  end

  defp decode_body(:delay_resp, <<o::binary-10, cid::binary-8, port::16, rest::binary>>) do
    with {:ok, o} <- Timestamp.decode(o),
         do: {:ok, %{receive_timestamp: o, requesting_port: {cid, port}}, rest}
  end

  defp decode_body(:pdelay_resp, <<o::binary-10, cid::binary-8, port::16, rest::binary>>) do
    with {:ok, o} <- Timestamp.decode(o),
         do: {:ok, %{request_receipt_timestamp: o, requesting_port: {cid, port}}, rest}
  end

  defp decode_body(
         :pdelay_resp_follow_up,
         <<o::binary-10, cid::binary-8, port::16, rest::binary>>
       ) do
    with {:ok, o} <- Timestamp.decode(o),
         do: {:ok, %{response_origin_timestamp: o, requesting_port: {cid, port}}, rest}
  end

  defp decode_body(
         :announce,
         <<o::binary-10, utc::signed-16, _::8, p1::8, class::8, acc::8, var::16, p2::8,
           gm::binary-8, steps::16, source::8, rest::binary>>
       ) do
    with {:ok, o} <- Timestamp.decode(o) do
      {:ok,
       %{
         origin_timestamp: o,
         current_utc_offset: utc,
         priority1: p1,
         clock_class: class,
         clock_accuracy: acc,
         offset_scaled_log_variance: var,
         priority2: p2,
         grandmaster_identity: gm,
         steps_removed: steps,
         time_source: source
       }, rest}
    end
  end

  defp decode_body(:signaling, <<cid::binary-8, port::16, rest::binary>>),
    do: {:ok, %{target_port: {cid, port}}, rest}

  defp decode_body(
         :management,
         <<cid::binary-8, port::16, start::8, hops::8, _::4, action::4, _::8, rest::binary>>
       ),
       do:
         {:ok,
          %{
            target_port: {cid, port},
            starting_boundary_hops: start,
            boundary_hops: hops,
            action: action
          }, rest}

  defp decode_body(_, _), do: {:error, :bad_body}
end
