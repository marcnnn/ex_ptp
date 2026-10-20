defmodule ExPtp.MediaClock do
  @moduledoc """
  RTP media clock derived from PTP time (AES67 clause 8): the media clock
  epoch is the PTP epoch and the RTP timestamp is `floor(t * rate) + offset`
  modulo 2^32, with `t` the PTP time in seconds. Exact integer arithmetic, so
  any sample rate works (48000, 44100, 96000, ...).

  `Nco` is the hardware shape: a phase accumulator advanced per system clock
  tick that emits one sample tick on every wrap.

      iex> alias ExPtp.{MediaClock, Timestamp}
      iex> MediaClock.rtp_timestamp(Timestamp.new(1, 0), 48_000)
      48000
      iex> MediaClock.rtp_timestamp(Timestamp.new(1, 20_833), 48_000)
      48000
      iex> MediaClock.rtp_timestamp(Timestamp.new(1, 20_834), 48_000)
      48001
      iex> MediaClock.rtp_timestamp(Timestamp.new(0, 0), 48_000, 1234)
      1234
      iex> MediaClock.sample_time(48_001, 48_000, Timestamp.new(1, 0)) |> Timestamp.to_ns()
      1_000_020_834
  """
  import Bitwise
  alias ExPtp.Timestamp

  @ns 1_000_000_000
  @mask 0xFFFFFFFF

  @doc "RTP timestamp (32 bit) at PTP time `ts` for sample `rate` Hz, plus `offset`."
  def rtp_timestamp(%Timestamp{seconds: s, nanoseconds: n}, rate, offset \\ 0),
    do: s * rate + div(n * rate, @ns) + offset &&& @mask

  @doc """
  PTP time of the first instant at which the media clock reads `rtp`, in the
  32-bit window nearest after `near` (a timestamp). Rounded up to whole ns.
  """
  def sample_time(rtp, rate, %Timestamp{} = near, offset \\ 0) do
    now = rtp_timestamp(near, rate, offset)
    delta = rtp - now &&& @mask
    base = div(Timestamp.to_ns(near) * rate, @ns)
    samples = base + delta
    Timestamp.from_ns(div(samples * @ns + rate - 1, rate))
  end

  defmodule Nco do
    @moduledoc """
    Media clock NCO model: `phase` (64-bit accumulator) plus `inc` per system
    clock tick; each wrap of the accumulator is one sample tick. `inc =
    rate / f_clk * 2^64`, rate-adjustable in ppb like the wallclock. The
    initial phase sets the phase of the sample ticks relative to the system clock.

        iex> alias ExPtp.MediaClock.Nco
        iex> import Bitwise
        iex> inc = Nco.increment(48_000, 125_000_000)
        iex> {_, ticks} = Enum.reduce(1..125_000, {1 <<< 63, 0}, fn _, {p, n} ->
        ...>   {tick, p} = Nco.step(p, inc)
        ...>   {p, n + tick}
        ...> end)
        iex> ticks
        48
    """
    import Bitwise
    @mod 1 <<< 64

    @doc "Increment for `rate` Hz from a `clk_hz` system clock, with `ppb` adjustment."
    def increment(rate, clk_hz, ppb \\ 0),
      do:
        Integer.floor_div(
          (rate <<< 64) * (1_000_000_000 + ppb) * 2 + clk_hz * 1_000_000_000,
          2 * clk_hz * 1_000_000_000
        )

    @doc "`{tick (0 or 1), next_phase}`."
    def step(phase, inc) do
      next = phase + inc
      {next >>> 64, next &&& @mod - 1}
    end
  end
end
