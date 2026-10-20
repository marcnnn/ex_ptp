defmodule ExPtp.Servo do
  @moduledoc """
  PI servo for the slave clock: offset from master (ns) in, frequency
  adjustment (ppb, to add to the local clock rate) out.

      integ' = integ - ki * err
      out    = integ' - kp * err

  `pi_step/5` is a stream kernel in the style of `ExSdr.DSP.Blocks`: written
  once against `NxFixed.Num`, instantiated as float (`NxFixed.Num.float/0`)
  or fixed point (`fixed_format/0`), `step(err, state, kp, ki, opts) ->
  {out, next_state}` with `state = integ`. It runs on the CPU reference
  (`run/4`, `NxFixed.run_scan/5`) and goes through `ExHdl.DSP.analyze_scan/3`
  for hardware. `ExPtp.Servo.FixedPI` is the same recurrence in plain
  integers (bit-identical, tested), used by `ExPtp.Port` where a per-sample
  Nx call would be too slow; `ExPtp.Servo.PI` is the float64 version.

  Gains follow linuxptp's defaults for the sync interval (`gains/1`).

      iex> alias ExPtp.Servo
      iex> {kp, ki} = Servo.gains(0)
      iex> {kp, ki}
      {0.7, 0.3}
      iex> f = Servo.fixed_format()
      iex> {outs, _} = Servo.run([1000.0, 1000.0], 0.0, {kp, ki}, f)
      iex> Enum.map(outs, &Float.round(&1, 1))
      [-1000.0, -1300.0]
  """
  import Nx.Defn
  import NxFixed.Num

  alias NxFixed.Num

  @err_frac 8
  @gain_frac 20

  @doc "Fixed point format of the state and output: 28 bits, 8 fractional (+-524 ppm)."
  def fixed_format, do: Num.q(28, @err_frac)

  @doc "Format of the error input: ns with 8 fractional bits in 32 bits (+-8 ms)."
  def err_format, do: Num.q(32, @err_frac)

  @doc "Format of the gains: 24 bits, 20 fractional."
  def gain_format, do: Num.q(24, @gain_frac)

  @doc """
  `{kp, ki}` for a sync interval of `2^log_interval` seconds, as linuxptp:
  `kp = min(0.7 * T^-0.3, 0.7 / T)`, `ki = min(0.3 * T^0.4, 0.3 / T)`.
  """
  def gains(log_interval) do
    t = :math.pow(2, log_interval)
    {min(0.7 * :math.pow(t, -0.3), 0.7 / t), min(0.3 * :math.pow(t, 0.4), 0.3 / t)}
  end

  @doc """
  One PI step. `err` is the offset from master, `integ` the integrator
  (state), `kp` and `ki` the gains; option `:format` the state/output format.
  """
  defn pi_step(err, integ, kp, ki, opts \\ []) do
    opts = keyword!(opts, [:format])
    format = opts[:format]
    integ_next = sub(integ, rescale(mul(ki, err), format)) |> quantize(format)
    out = sub(integ_next, rescale(mul(kp, err), format)) |> quantize(format)
    {out, integ_next}
  end

  @doc """
  Lock detector kernel: `err` (s32, raw error of `err_format/0`), state
  `run` (u8, consecutive in-threshold samples, saturating at 255), params
  `thr` (s32, raw threshold) and `needed` (u8). Outputs 1 once `needed`
  consecutive samples were within `thr`, else 0; equal to
  `ExPtp.Servo.Lock` without hysteresis (`unlock_factor` 1).
  """
  defn lock_step(err, run, thr, needed) do
    inside = Nx.less_equal(Nx.abs(Nx.as_type(err, :s64)), Nx.as_type(thr, :s64))
    next = Nx.select(inside, Nx.min(Nx.as_type(run, :u16) + 1, 255), 0) |> Nx.as_type(:u8)
    {Nx.greater_equal(next, needed) |> Nx.as_type(:u8), next}
  end

  @doc """
  Runs `pi_step/5` over a list of offsets (ns, floats) from integrator
  `integ0` (ppb) in `format` (`NxFixed.Num.float/0` or `fixed_format/0`).
  Returns `{outputs_ppb, final_integrator_ppb}` as floats.
  """
  def run(errs, integ0, {kp, ki}, format) do
    efmt = if format.kind == :float, do: format, else: err_format()
    gfmt = if format.kind == :float, do: format, else: gain_format()

    samples = Enum.map(errs, &Num.constant(&1, efmt))
    params = [Num.constant(kp, gfmt), Num.constant(ki, gfmt)]

    {outs, state} =
      NxFixed.run_scan(&pi_step/5, samples, Num.constant(integ0, format), params,
        kernel_opts: [format: format]
      )

    {Enum.map(outs, &Num.to_float/1), Num.to_float(state)}
  end
end
