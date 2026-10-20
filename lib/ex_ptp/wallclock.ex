defmodule ExPtp.Wallclock do
  @moduledoc """
  Reference model of the hardware wallclock: seconds, nanoseconds and a
  32-bit sub-nanosecond fraction, advanced once per system clock tick by an
  increment in units of 2^-32 ns. The increment is the rate control
  (`increment/2`: nominal period plus a ppb adjustment); `step/2` jumps the
  phase and `slew/3` spreads a phase correction exactly over a number of
  ticks. Everything is integer arithmetic and deterministic, so it can be
  compared bit for bit with the RTL.

  `advance/3` equals repeated `tick/2` but runs in constant time (while no
  slew is in progress).

      iex> alias ExPtp.Wallclock, as: W
      iex> nominal = W.nominal_increment(125_000_000)
      iex> nominal == 8 * 2 ** 32
      true
      iex> w = W.new() |> W.advance(nominal, 125_000_000)
      iex> {w.seconds, w.nanoseconds}
      {1, 0}
      iex> fast = W.increment(nominal, 1000)
      iex> w = W.new() |> W.advance(fast, 125_000_000)
      iex> {w.seconds, w.nanoseconds}
      {1, 1000}
  """
  import Bitwise
  alias ExPtp.Timestamp

  @ns 1_000_000_000
  @frac_bits 32
  @modulus @ns <<< @frac_bits

  defstruct seconds: 0, nanoseconds: 0, fraction: 0, slew_total: 0, slew_ticks: 0

  @type t :: %__MODULE__{}

  @doc "A clock at `timestamp` (default: the epoch)."
  def new(%Timestamp{seconds: s, nanoseconds: n} \\ %Timestamp{}),
    do: %__MODULE__{seconds: s, nanoseconds: n}

  @doc "Nominal increment (2^-32 ns per tick) for a system clock of `hz`."
  def nominal_increment(hz), do: Integer.floor_div(@ns <<< @frac_bits, hz)

  @doc "Increment for a rate adjustment of `ppb` (positive: the clock runs faster)."
  def increment(nominal, ppb) when is_integer(ppb),
    do: nominal + Integer.floor_div(nominal * ppb + 500_000_000, @ns)

  def increment(nominal, ppb) when is_float(ppb), do: nominal + round(nominal * ppb / @ns)

  @doc "One tick with increment `inc` (plus the current slew share)."
  def tick(%__MODULE__{} = w, inc), do: advance(w, inc, 1)

  @doc "`{time, state}` after one tick; the shape of a scan-kernel step."
  def step(%__MODULE__{} = w, inc) do
    w = tick(w, inc)
    {time(w), w}
  end

  @doc "`n` ticks in one go; identical to `n` calls of `tick/2`."
  def advance(w, _inc, 0), do: w

  def advance(%__MODULE__{slew_ticks: 0} = w, inc, n), do: add_frac(w, inc * n)

  def advance(%__MODULE__{slew_ticks: st, slew_total: total} = w, inc, n) when n >= st do
    advance(add_frac(%{w | slew_ticks: 0, slew_total: 0}, inc * st + total), inc, n - st)
  end

  def advance(%__MODULE__{slew_ticks: st, slew_total: total} = w, inc, n) do
    taken = slew_share(total, st, n)
    %{add_frac(w, inc * n + taken) | slew_ticks: st - n, slew_total: total - taken}
  end

  # The exact sum of the per-tick shares floor(total / ticks) over n ticks.
  defp slew_share(total, ticks, n),
    do:
      Enum.reduce(1..n//1, {total, ticks, 0}, fn _, {t, k, acc} ->
        q = Integer.floor_div(t, k)
        {t - q, k - 1, acc + q}
      end)
      |> elem(2)

  @doc "Jumps the phase by `delta_ns` (signed integer ns); the clock stays at or above the epoch."
  def step_phase(%__MODULE__{} = w, delta_ns), do: add_frac(w, delta_ns <<< @frac_bits)

  @doc "Adds `delta_ns` over the next `ticks` ticks, on top of the increment."
  def slew(%__MODULE__{} = w, delta_ns, ticks) when ticks > 0,
    do: %{
      w
      | slew_total: w.slew_total + (delta_ns <<< @frac_bits),
        slew_ticks: max(w.slew_ticks, ticks)
    }

  defp add_frac(w, delta) do
    total = (w.nanoseconds <<< @frac_bits) + w.fraction + delta
    carry = Integer.floor_div(total, @modulus)
    rem = Integer.mod(total, @modulus)

    if w.seconds + carry < 0 do
      %{w | seconds: 0, nanoseconds: 0, fraction: 0}
    else
      %{
        w
        | seconds: w.seconds + carry,
          nanoseconds: rem >>> @frac_bits,
          fraction: rem &&& 0xFFFFFFFF
      }
    end
  end

  @doc "Current time (the sub-nanosecond fraction truncated)."
  def time(%__MODULE__{seconds: s, nanoseconds: n}), do: %Timestamp{seconds: s, nanoseconds: n}

  @doc "Current time in 2^-32 ns units since the epoch."
  def to_fixed(%__MODULE__{} = w),
    do: ((w.seconds * @ns + w.nanoseconds) <<< @frac_bits) + w.fraction
end
