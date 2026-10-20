defmodule ExPtp.Timestamp do
  @moduledoc """
  PTP timestamp: 48-bit seconds and 32-bit nanoseconds (< 10^9), 10 bytes on
  the wire. Differences are integers, in nanoseconds (`diff_ns/2`) or scaled
  nanoseconds (`diff/2`, see `ExPtp.Correction`).

      iex> a = ExPtp.Timestamp.new(10, 999_999_999)
      iex> b = ExPtp.Timestamp.add_ns(a, 2)
      iex> b
      %ExPtp.Timestamp{seconds: 11, nanoseconds: 1}
      iex> ExPtp.Timestamp.diff_ns(b, a)
      2
      iex> ExPtp.Timestamp.decode(ExPtp.Timestamp.encode(b))
      {:ok, b}
  """
  import Bitwise

  @ns 1_000_000_000
  @max_seconds (1 <<< 48) - 1

  defstruct seconds: 0, nanoseconds: 0

  @type t :: %__MODULE__{seconds: non_neg_integer(), nanoseconds: non_neg_integer()}

  @doc "Timestamp from seconds and nanoseconds; nanoseconds beyond 10^9 carry."
  def new(seconds, nanoseconds \\ 0), do: from_ns(seconds * @ns + nanoseconds)

  @doc "Timestamp from total nanoseconds since the epoch (clamped at 0)."
  def from_ns(total) when is_integer(total) do
    total = max(total, 0)
    %__MODULE__{seconds: min(div(total, @ns), @max_seconds), nanoseconds: rem(total, @ns)}
  end

  @doc "Total nanoseconds since the epoch."
  def to_ns(%__MODULE__{seconds: s, nanoseconds: n}), do: s * @ns + n

  @doc "Adds integer nanoseconds (may be negative)."
  def add_ns(%__MODULE__{} = t, ns), do: from_ns(to_ns(t) + ns)

  @doc "Adds scaled nanoseconds, truncating below 1 ns."
  def add(%__MODULE__{} = t, c), do: from_ns(to_ns(t) + (c >>> 16))

  @doc "`a - b` in nanoseconds."
  def diff_ns(a, b), do: to_ns(a) - to_ns(b)

  @doc "`a - b` in scaled nanoseconds."
  def diff(a, b), do: diff_ns(a, b) <<< 16

  @doc "`:lt | :eq | :gt`."
  def compare(a, b) do
    case {to_ns(a), to_ns(b)} do
      {x, y} when x < y -> :lt
      {x, y} when x > y -> :gt
      _ -> :eq
    end
  end

  @doc "Wire encoding: 6 bytes seconds, 4 bytes nanoseconds."
  def encode(%__MODULE__{seconds: s, nanoseconds: n}), do: <<s::48, n::32>>

  @doc "Decodes 10 bytes; nanoseconds >= 10^9 are rejected."
  def decode(<<s::48, n::32>>) when n < @ns, do: {:ok, %__MODULE__{seconds: s, nanoseconds: n}}
  def decode(_), do: {:error, :bad_timestamp}
end
