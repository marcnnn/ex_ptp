defmodule ExPtp.Clock.Wallclock do
  @moduledoc """
  `ExPtp.Clock` over the bit-exact wallclock model (`ExPtp.Wallclock`), for simulations
  and tests of servos. The clock is state that a servo changes while a bench advances
  time, so it lives in an `Agent` (the handle is its pid); everything inside is the
  integer model: `adj_freq/2` writes the increment (`Wallclock.increment/2`), `step/2`
  is `Wallclock.step_phase/2`, `set/2` is `Wallclock.new/1` (fraction cleared).

  Time passes only when the bench calls `advance/2`: `true_ns` of reference time are
  `true_ns * hz * (1 + drift_ppb / 1e9) / 1e9` ticks of the local oscillator (the drift is
  the crystal's error, `adj_freq/2` is the correction on top, as in the hardware: a clock with
  +50 ppm crystal error needs -50 ppm). The tick count is exact, no rounding drift.

  Options of `start/1`: `:hz` (system clock, 125 MHz), `:time` (initial `ExPtp.Timestamp`,
  the epoch), `:drift_ppb` (0), `:adj_ppb` (initial adjustment, 0).

      iex> alias ExPtp.Clock.Wallclock, as: C
      iex> clock = C.start(hz: 1_000_000, drift_ppb: 50_000)
      iex> {_, pid} = clock
      iex> C.advance(pid, 1_000_000_000)
      iex> ExPtp.Clock.now(clock)
      %ExPtp.Timestamp{seconds: 1, nanoseconds: 50_000}
  """
  @behaviour ExPtp.Clock

  alias ExPtp.{Timestamp, Wallclock}

  @ns 1_000_000_000

  @doc "Starts a clock (linked to the caller) and returns the `{module, pid}` clock."
  def start(opts \\ []) do
    hz = Keyword.get(opts, :hz, 125_000_000)
    nominal = Wallclock.nominal_increment(hz)

    {:ok, pid} =
      Agent.start_link(fn ->
        %{
          w: Wallclock.new(Keyword.get(opts, :time, %Timestamp{})),
          nominal: nominal,
          inc: Wallclock.increment(nominal, Keyword.get(opts, :adj_ppb, 0)),
          hz: hz,
          drift: Keyword.get(opts, :drift_ppb, 0),
          true_ns: 0,
          ticks: 0
        }
      end)

    {__MODULE__, pid}
  end

  @doc "Lets `true_ns` of reference time pass."
  def advance(pid, true_ns) when true_ns >= 0 do
    Agent.update(pid, fn s ->
      total = s.true_ns + true_ns
      target = div(total * s.hz * (@ns + s.drift), @ns * @ns)
      %{s | w: Wallclock.advance(s.w, s.inc, target - s.ticks), true_ns: total, ticks: target}
    end)
  end

  @doc "The increment register (2^-32 ns per tick)."
  def increment(pid), do: Agent.get(pid, & &1.inc)

  @doc "The model state (`ExPtp.Wallclock`)."
  def state(pid), do: Agent.get(pid, & &1.w)

  @doc "Changes the crystal error from now on."
  def set_drift(pid, drift_ppb), do: Agent.update(pid, &%{&1 | drift: drift_ppb})

  @impl true
  def now(pid), do: Agent.get(pid, &Wallclock.time(&1.w))

  @impl true
  def freq(pid), do: Agent.get(pid, &((&1.inc - &1.nominal) * 1.0e9 / &1.nominal))

  @impl true
  def adj_freq(pid, ppb),
    do: Agent.update(pid, &%{&1 | inc: Wallclock.increment(&1.nominal, ppb)})

  @impl true
  def step(pid, delta_ns) when is_integer(delta_ns),
    do: Agent.update(pid, &%{&1 | w: Wallclock.step_phase(&1.w, delta_ns)})

  @impl true
  def set(pid, %Timestamp{} = t), do: Agent.update(pid, &%{&1 | w: Wallclock.new(t)})

  @impl true
  def caps(_), do: [:adj_freq, :step, :set]
end
