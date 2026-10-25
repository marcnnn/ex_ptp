defmodule ExPtp.Servo.Profile do
  @moduledoc """
  Servo, lock detector and outlier filter settings for a kind of timestamps.

  - `:hardware` (the default): MAC timestamps, jitter of nanoseconds. linuxptp's
    hardware gains (`ExPtp.Servo.gains/1`), lock within 500 ns, no outlier filter.
  - `:software`: kernel or user space timestamps, jitter of tens of microseconds
    with spikes of hundreds. linuxptp's software gains (`kp` scale 0.1, `ki` scale
    0.001 in `pi.c`), lock within 100 us (unlock above 300 us), an outlier filter in
    front of the servo and the lock detector, a step threshold of 1 ms and a slower
    mean path delay filter.

  `ExPtp.Port` takes the profile from its `:timestamping` option, or from the
  transport's `timestamping/1` callback, and every field can be overridden by
  the port options of the same name (`:lock_threshold_ns`, `:lock_count`,
  `:unlock_factor`, `:step_threshold_ns`, `:mpd_shift`) or `:servo_gains`
  (`{kp, ki}` or a function of the log sync interval).

      iex> alias ExPtp.Servo.Profile
      iex> {kp, ki} = Profile.gains(Profile.get(:software), -3)
      iex> {Float.round(kp, 3), Float.round(ki, 5)}
      {0.187, 0.00044}
      iex> Profile.gains(Profile.get(:hardware), 0)
      {0.7, 0.3}
  """
  defstruct name: :hardware,
            kp_scale: 0.7,
            ki_scale: 0.3,
            lock_threshold_ns: 500,
            lock_count: 5,
            unlock_factor: 2,
            step_threshold_ns: 100_000,
            mpd_shift: 2,
            outlier: nil

  @type t :: %__MODULE__{}

  @doc "Profile for `:hardware` or `:software` timestamps."
  def get(:hardware), do: %__MODULE__{}

  def get(:software) do
    %__MODULE__{
      name: :software,
      kp_scale: 0.1,
      ki_scale: 0.001,
      lock_threshold_ns: 100_000,
      lock_count: 5,
      unlock_factor: 3,
      step_threshold_ns: 1_000_000,
      mpd_shift: 3,
      outlier: %{window: 16, factor: 4, floor_ns: 50_000, min_samples: 4, max_run: 3}
    }
  end

  @doc """
  `{kp, ki}` for a sync interval of `2^log_interval` seconds, as linuxptp's
  `pi.c`: `kp = min(kp_scale * T^-0.3, 0.7 / T)`, `ki = min(ki_scale * T^0.4, 0.3 / T)`.
  """
  def gains(%__MODULE__{} = p, log_interval) do
    t = :math.pow(2, log_interval)
    {min(p.kp_scale * :math.pow(t, -0.3), 0.7 / t), min(p.ki_scale * :math.pow(t, 0.4), 0.3 / t)}
  end
end
