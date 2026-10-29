defmodule ExPtp.Clock do
  @moduledoc """
  An adjustable clock, the thing a servo steers. A clock is a `{module, handle}`
  pair like `ExPtp.Transport`; the module implements these callbacks on the
  handle, the functions of this module dispatch. Time is an `ExPtp.Timestamp`.

  | Callback | Meaning |
  |---|---|
  | `now/1` | the clock's time |
  | `freq/1` | frequency offset from nominal in ppb that is applied now (0 for a clock that cannot be adjusted) |
  | `adj_freq/2` | sets the frequency offset, absolute ppb from nominal (positive: runs faster); not a delta |
  | `step/2` | jumps the phase by a signed number of ns |
  | `set/2` | sets the time |
  | `caps/1` | what the clock accepts: a list of `:adj_freq`, `:step`, `:set` (empty: read only) |

  A read-only clock (`ExPtp.Clock.System`) returns `{:error, :read_only}` from the three
  commands; `ExPtp.SoftServo` in `:monitor` mode works on it, in `:servo` mode it refuses it.
  `freq/1` exists for bumpless handover: a servo that takes over starts its integrator
  from the rate the clock already has instead of from zero.

  Implementations: `ExPtp.Clock.Wallclock` (the bit-exact wallclock model), `ExPtp.Clock.System`
  (CLOCK_REALTIME, read only); the card's wallclock (increment, step and set registers)
  lives in aes67_card.

      iex> clock = ExPtp.Clock.Wallclock.start(time: ExPtp.Timestamp.new(100))
      iex> :ok = ExPtp.Clock.adj_freq(clock, 1000)
      iex> Float.round(ExPtp.Clock.freq(clock), 1)
      1000.0
      iex> ExPtp.Clock.steerable?(clock)
      true
      iex> ExPtp.Clock.steerable?({ExPtp.Clock.System, []})
      false
  """
  alias ExPtp.Timestamp

  @type handle :: term()
  @type t :: {module, handle}
  @type cap :: :adj_freq | :step | :set

  @callback now(handle) :: Timestamp.t()
  @callback freq(handle) :: number
  @callback adj_freq(handle, ppb :: number) :: :ok | {:error, term}
  @callback step(handle, delta_ns :: integer) :: :ok | {:error, term}
  @callback set(handle, Timestamp.t()) :: :ok | {:error, term}
  @callback caps(handle) :: [cap]

  @doc "Time of the clock."
  def now({mod, h}), do: mod.now(h)

  @doc "Applied frequency offset, ppb."
  def freq({mod, h}), do: mod.freq(h)

  @doc "Sets the frequency offset (absolute ppb from nominal)."
  def adj_freq({mod, h}, ppb), do: mod.adj_freq(h, ppb)

  @doc "Steps the phase by `delta_ns`."
  def step({mod, h}, delta_ns), do: mod.step(h, delta_ns)

  @doc "Sets the time."
  def set({mod, h}, %Timestamp{} = t), do: mod.set(h, t)

  @doc "Capabilities, a list of `:adj_freq`, `:step`, `:set`."
  def caps({mod, h}), do: mod.caps(h)

  @doc "True when the clock accepts frequency adjustments (a servo can steer it)."
  def steerable?(clock), do: :adj_freq in caps(clock)
end
