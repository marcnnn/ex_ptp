defmodule ExPtp.SoftServo do
  @moduledoc """
  The servo loop in software (mode S of the card, or any host clock): offset samples
  in, PI controller, lock detector and phase step, result applied through an
  `ExPtp.Clock`. The hardware servo (`ExPtp.RTL.Servo`) does the same in fabric; the two
  share the arithmetic (`ExPtp.Servo.FixedPI`, bit-identical to the scan kernel, or the float
  `ExPtp.Servo.PI`), the gains (`ExPtp.Servo.Profile`) and the lock detector
  (`ExPtp.Servo.Lock`), so a loop gives the same lock behaviour in either place.

  The state is a plain struct, every call returns `{event, servo}`; the clock is the only
  side effect. Input is either a ready offset (`update/3`, ns) or the timestamps of the
  exchange (`delay/6`, `sync/4`, `exchange/7`, from `ExPtp.Delay`: `t1` Sync origin, `t2` its
  receipt, `t3` Delay_Req origin, `t4` its receipt, corrections in scaled ns; the mean path
  delay is filtered as in `ExPtp.Port`, `mpd_shift` of the profile).

  | Event | Meaning |
  |---|---|
  | `:servo` | PI step done, new frequency applied with `adj_freq` |
  | `:step` | offset above `step_threshold_ns`: the phase was stepped, lock cleared, the rate (integrator) kept |
  | `:reject` | outlier filter (software profile) dropped the sample |
  | `:monitor` | recorded only, the clock was not touched |
  | `:no_path_delay` | `sync/4` before any mean path delay is known |
  | `{:error, reason}` | the clock refused the command |

  ## Modes

  `mode: :servo` (default) steers; the clock must be steerable (`ExPtp.Clock.steerable?/1`).
  `mode: :monitor` takes the same input, runs the lock detector and the statistics and never
  calls the clock (the clock may be `nil` or read only): what ptp4l `free_running 1` does, used to
  compare a reference against a free running or hardware steered clock. `set_mode/2` switches
  at run time.

  ## Bumpless start

  A servo that starts (or resumes, `set_mode(s, :servo)`) does not start the integrator at
  zero but at the clock's present rate, `ExPtp.Clock.freq/1` (option `:ppb` overrides). The
  card's hardware to software handover therefore continues at the increment the hardware
  servo left in the wallclock; the first sample then moves the rate by `(kp + ki) * offset`
  like in steady state. For the other direction see `ppb/1`, `ExPtp.RTL.Servo.preload_for/2`.

  ## Status

  `status/1` has the fields of the hardware servo's status registers (`locked`, `ppb`,
  `offset_ns`, `mpd_ns`, `samples`, `steps`) plus `mode` and `rejected`; `stats/1` is the
  running statistics of every offset seen (`n`, `mean_ns`, `stddev_ns`, `rms_ns`, `max_abs_ns`).

  Options of `new/2`: `:mode`, `:profile` (`:hardware` default or `:software`, see
  `ExPtp.Servo.Profile`), `:log_interval` (sync interval, -3, for the gains),
  `:servo_gains` (`{kp, ki}` or a function of the log interval), `:servo` (`:fixed` default
  or `:float`), `:ppb` (initial rate), and the profile fields `:lock_threshold_ns`,
  `:lock_count`, `:unlock_factor`, `:step_threshold_ns`, `:mpd_shift`.

      iex> alias ExPtp.{SoftServo, Clock}
      iex> clock = Clock.Wallclock.start()
      iex> s = SoftServo.new(clock, servo_gains: {0.7, 0.3})
      iex> {:servo, s} = SoftServo.update(s, 1000)
      iex> SoftServo.status(s).ppb
      -1000.0
      iex> Clock.freq(clock) |> Float.round(1)
      -1000.0
      iex> {:monitor, m} = SoftServo.new(nil, mode: :monitor) |> SoftServo.update(1000)
      iex> SoftServo.status(m).offset_ns
      1000.0
  """
  alias ExPtp.{Clock, Correction, Delay}
  alias ExPtp.Servo.{FixedPI, Lock, Outlier, PI}
  alias ExPtp.Servo.Profile

  defstruct [
    :clock,
    :mode,
    :kind,
    :profile,
    :cfg,
    :gains,
    :servo,
    :lock,
    :outlier,
    mpd: nil,
    offset: nil,
    ppb: 0.0,
    samples: 0,
    steps: 0,
    rejected: 0,
    n: 0,
    mean: 0.0,
    m2: 0.0,
    sumsq: 0.0,
    max_abs: 0.0
  ]

  @type t :: %__MODULE__{}

  @cfg_keys [:lock_threshold_ns, :lock_count, :unlock_factor, :step_threshold_ns, :mpd_shift]

  @doc "A servo on `clock` (an `ExPtp.Clock`, `nil` allowed in `:monitor` mode); options in the module doc."
  def new(clock, opts \\ []) do
    profile = Profile.get(Keyword.get(opts, :profile, :hardware))
    mode = Keyword.get(opts, :mode, :servo)
    mode in [:servo, :monitor] or raise ArgumentError, "mode must be :servo or :monitor"

    cfg = Map.new(@cfg_keys, fn k -> {k, Keyword.get(opts, k, Map.fetch!(profile, k))} end)

    s = %__MODULE__{
      clock: clock,
      mode: :monitor,
      kind: Keyword.get(opts, :servo, :fixed),
      profile: profile,
      cfg: cfg,
      gains: gains(opts, profile, Keyword.get(opts, :log_interval, -3)),
      lock: new_lock(cfg)
    }

    s = %{s | outlier: new_outlier(profile)}
    if mode == :servo, do: engage(s, Keyword.get(opts, :ppb)), else: s
  end

  @doc """
  Switches mode. To `:servo` the integrator restarts from the clock's present rate and
  the lock detector from unlocked (bumpless); to `:monitor` the clock keeps its last rate.
  """
  def set_mode(%__MODULE__{mode: mode} = s, mode), do: s
  def set_mode(%__MODULE__{} = s, :monitor), do: %{s | mode: :monitor, servo: nil}
  def set_mode(%__MODULE__{} = s, :servo), do: engage(%{s | lock: new_lock(s.cfg)}, nil)

  defp engage(%{clock: nil}, _), do: raise(ArgumentError, "mode :servo needs a clock")

  defp engage(%{clock: clock, gains: {kp, ki}} = s, ppb) do
    Clock.steerable?(clock) or raise ArgumentError, "the clock is read only, use mode: :monitor"
    ppb = ppb || Clock.freq(clock)

    servo =
      case s.kind do
        :fixed -> FixedPI.new(kp, ki, ppb)
        :float -> PI.new(kp, ki, integ: ppb * 1.0)
      end

    %{s | mode: :servo, servo: servo, ppb: ppb * 1.0, outlier: new_outlier(s.profile)}
  end

  @doc """
  Filters a mean path delay sample (scaled ns, from `ExPtp.Delay`); the first one is
  taken as is, then `mpd += (sample - mpd) >> mpd_shift`. Negative samples are ignored.
  """
  def path_delay(%__MODULE__{} = s, sample) when sample < 0, do: s
  def path_delay(%__MODULE__{mpd: nil} = s, sample), do: %{s | mpd: sample}

  def path_delay(%__MODULE__{} = s, sample),
    do: %{s | mpd: s.mpd + Bitwise.bsr(sample - s.mpd, s.cfg.mpd_shift)}

  @doc "Mean path delay from the four timestamps of a delay request-response exchange (`ExPtp.Delay.e2e_mean_path_delay/6`)."
  def delay(%__MODULE__{} = s, t1, t2, t3, t4, corrections \\ {0, 0}) do
    {c_sync, c_resp} = corrections
    path_delay(s, Delay.e2e_mean_path_delay(t1, t2, t3, t4, c_sync, c_resp))
  end

  @doc "Offset of a Sync (`t1` origin, `t2` receipt, correction in scaled ns) with the current mean path delay."
  def sync(s, t1, t2, c \\ 0)
  def sync(%__MODULE__{mpd: nil} = s, _t1, _t2, _c), do: {:no_path_delay, s}
  def sync(%__MODULE__{} = s, t1, t2, c), do: feed(s, Delay.offset_from_master(t1, t2, c, s.mpd))

  @doc """
  One complete exchange, as the hardware offset block takes it: `delay/6` with the exchange's
  four timestamps, then `sync/4` with `t1`, `t2`.
  """
  def exchange(%__MODULE__{} = s, t1, t2, t3, t4, c_sync \\ 0, c_resp \\ 0),
    do: s |> delay(t1, t2, t3, t4, {c_sync, c_resp}) |> sync(t1, t2, c_sync)

  @doc "A ready offset from master in ns (slave minus master), optionally with the mean path delay in ns for the status."
  def update(%__MODULE__{} = s, offset_ns, mpd_ns \\ nil) do
    s = if mpd_ns, do: %{s | mpd: Correction.from_ns(mpd_ns)}, else: s
    feed(s, Correction.from_ns(offset_ns))
  end

  defp feed(s, offset) do
    off_ns = Correction.to_ns(offset)
    s = record(%{s | offset: offset}, off_ns)
    {verdict, s} = outlier_check(s, off_ns)

    cond do
      verdict == :reject ->
        {:reject, %{s | rejected: s.rejected + 1}}

      s.mode == :monitor ->
        {:monitor, %{s | lock: Lock.update(s.lock, off_ns)}}

      abs(off_ns) > s.cfg.step_threshold_ns ->
        case Clock.step(s.clock, -round(off_ns)) do
          :ok ->
            {:step,
             %{s | steps: s.steps + 1, lock: new_lock(s.cfg), outlier: new_outlier(s.profile)}}

          {:error, _} = e ->
            {e, s}
        end

      true ->
        {ppb, servo} = pi_step(s.servo, offset)

        case Clock.adj_freq(s.clock, ppb) do
          :ok ->
            {:servo, %{s | servo: servo, ppb: ppb, lock: Lock.update(s.lock, off_ns)}}

          {:error, _} = e ->
            {e, s}
        end
    end
  end

  defp pi_step(%FixedPI{} = f, offset) do
    {raw, f} = FixedPI.step(f, FixedPI.err_from_scaled(offset))
    {FixedPI.ppb(raw), f}
  end

  defp pi_step(%PI{} = pi, offset), do: PI.step(pi, Correction.to_ns(offset))

  @doc """
  Status like the hardware servo's registers: `%{mode, locked, ppb, offset_ns, mpd_ns,
  samples, steps, rejected}`. `ppb` is the rate last applied (0.0 until a `:servo` step
  and in a monitor that never steered), `offset_ns` and `mpd_ns` are `nil` before the
  first sample.
  """
  def status(%__MODULE__{} = s) do
    %{
      mode: s.mode,
      locked: s.lock.locked,
      ppb: s.ppb,
      offset_ns: s.offset && Correction.to_ns(s.offset),
      mpd_ns: s.mpd && Correction.to_ns(s.mpd),
      samples: s.samples,
      steps: s.steps,
      rejected: s.rejected
    }
  end

  @doc "The rate (ppb) the servo last applied; what to preload into the hardware servo for the handover to H."
  def ppb(%__MODULE__{ppb: ppb}), do: ppb

  @doc "Statistics of every offset seen: `%{n, mean_ns, stddev_ns, rms_ns, max_abs_ns}` (`nil` fields before two samples)."
  def stats(%__MODULE__{n: n} = s) do
    %{
      n: n,
      mean_ns: if(n > 0, do: s.mean),
      stddev_ns: if(n > 1, do: :math.sqrt(s.m2 / (n - 1))),
      rms_ns: if(n > 0, do: :math.sqrt(s.sumsq / n)),
      max_abs_ns: if(n > 0, do: s.max_abs)
    }
  end

  defp record(s, x) do
    n = s.n + 1
    d = x - s.mean
    mean = s.mean + d / n

    %{
      s
      | samples: s.samples + 1,
        n: n,
        mean: mean,
        m2: s.m2 + d * (x - mean),
        sumsq: s.sumsq + x * x,
        max_abs: max(s.max_abs, abs(x))
    }
  end

  defp outlier_check(%{profile: %{outlier: nil}} = s, _), do: {:ok, s}

  defp outlier_check(s, off_ns) do
    {verdict, f} = Outlier.check(s.outlier, off_ns)
    {verdict, %{s | outlier: f}}
  end

  defp new_outlier(%{outlier: nil}), do: nil
  defp new_outlier(%{outlier: cfg}), do: Outlier.new(cfg)

  defp new_lock(cfg), do: Lock.new(cfg.lock_threshold_ns, cfg.lock_count, cfg.unlock_factor)

  defp gains(opts, profile, log_interval) do
    case Keyword.get(opts, :servo_gains) do
      nil -> Profile.gains(profile, log_interval)
      f when is_function(f, 1) -> f.(log_interval)
      {_kp, _ki} = g -> g
    end
  end
end
