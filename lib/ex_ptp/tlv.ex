defmodule ExPtp.TLV do
  @moduledoc """
  Generic TLV (type u16, length u16, value). Decoding keeps the value as an
  opaque binary; `path_trace/1` and `path_trace_ids/1` cover the one TLV the
  BMCA side cares about.

      iex> tlv = %ExPtp.TLV{type: 0x2000, value: <<1, 2, 3, 4>>}
      iex> ExPtp.TLV.decode_all(ExPtp.TLV.encode(tlv))
      {:ok, [tlv]}
      iex> ExPtp.TLV.decode_all(<<0, 8, 0, 9, 1>>)
      {:error, :bad_tlv}
  """
  defstruct [:type, value: <<>>]

  @type t :: %__MODULE__{type: 0..0xFFFF, value: binary()}

  @management 0x0001
  @management_error_status 0x0002
  @organization_extension 0x0003
  @path_trace 0x8
  @alternate_time_offset_indicator 0x2009

  def management, do: @management
  def management_error_status, do: @management_error_status
  def organization_extension, do: @organization_extension
  def alternate_time_offset_indicator, do: @alternate_time_offset_indicator

  @doc "One TLV on the wire."
  def encode(%__MODULE__{type: type, value: value}),
    do: <<type::16, byte_size(value)::16, value::binary>>

  @doc "A list of TLVs on the wire."
  def encode_all(tlvs), do: tlvs |> Enum.map(&encode/1) |> IO.iodata_to_binary()

  @doc "Parses a TLV sequence that fills the binary exactly."
  def decode_all(bin), do: decode_all(bin, [])

  defp decode_all(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_all(<<type::16, len::16, value::binary-size(len), rest::binary>>, acc),
    do: decode_all(rest, [%__MODULE__{type: type, value: value} | acc])

  defp decode_all(_, _), do: {:error, :bad_tlv}

  @doc "PATH_TRACE TLV from a list of 8-byte clock identities."
  def path_trace(ids), do: %__MODULE__{type: @path_trace, value: IO.iodata_to_binary(ids)}

  @doc "Clock identities of a PATH_TRACE TLV (trailing partial identity dropped)."
  def path_trace_ids(%__MODULE__{type: @path_trace, value: v}),
    do: for(<<id::binary-8 <- v>>, do: id)

  def path_trace_ids(_), do: []
end
