defmodule ExPtp.Correction do
  @moduledoc """
  correctionField and TimeInterval values: signed 64-bit integers in scaled
  nanoseconds (units of 2^-16 ns, IEEE 1588-2019 clause 13.3.2.9).

      iex> ExPtp.Correction.from_ns(1.5)
      98304
      iex> ExPtp.Correction.to_ns(98304)
      1.5
      iex> ExPtp.Correction.half(ExPtp.Correction.from_ns(3))
      98304
  """
  import Bitwise

  @max (1 <<< 63) - 1
  @min -(1 <<< 63)

  @doc "Scaled ns from nanoseconds (integer or float), rounded to nearest."
  def from_ns(ns) when is_integer(ns), do: ns <<< 16
  def from_ns(ns) when is_float(ns), do: round(ns * 65_536)

  @doc "Nanoseconds as a float."
  def to_ns(c), do: c / 65_536

  @doc "Nanoseconds rounded to an integer (nearest, ties up)."
  def to_ns_rounded(c), do: (c + 32_768) >>> 16

  @doc "Sum, saturated to the signed 64-bit range."
  def add(a, b), do: saturate(a + b)

  @doc "Difference, saturated to the signed 64-bit range."
  def sub(a, b), do: saturate(a - b)

  @doc "Half, as an arithmetic shift (rounds towards minus infinity like the hardware)."
  def half(c), do: c >>> 1

  @doc "Clamps to the signed 64-bit range."
  def saturate(c), do: c |> max(@min) |> min(@max)

  @doc "Wire encoding: 8 bytes, big endian, two's complement."
  def encode(c), do: <<saturate(c)::signed-64>>

  @doc "Decodes 8 bytes."
  def decode(<<c::signed-64>>), do: c
end
