defmodule ExPtp.Servo.FixedPI do
  @moduledoc """
  `ExPtp.Servo.pi_step/5` in plain integers: bit-identical to the Nx kernel
  in `ExPtp.Servo.fixed_format/0` (tested), fast enough to call per sample.

  Values are raw integers: error in ns with 8 fractional bits (s32), state and
  output in ppb with 8 fractional bits (s28), gains with 20 fractional bits
  (s24). Products are rounded to nearest (ties up) and saturated like the
  kernel's `rescale` and `quantize`.

      iex> alias ExPtp.Servo.FixedPI
      iex> s = FixedPI.new(0.7, 0.3)
      iex> {out, s} = FixedPI.step(s, FixedPI.err(1000.0))
      iex> FixedPI.ppb(out)
      -1000.0
      iex> {out, _} = FixedPI.step(s, FixedPI.err(1000.0))
      iex> Float.round(FixedPI.ppb(out), 1)
      -1300.0
  """
  import Bitwise

  @frac 8
  @gain_frac 20
  @out_min -(1 <<< 27)
  @out_max (1 <<< 27) - 1

  defstruct kp: 0, ki: 0, integ: 0

  @doc "Servo with gains `kp`, `ki` (floats, quantized to 20 fractional bits)."
  def new(kp, ki, integ_ppb \\ 0.0),
    do: %__MODULE__{kp: gain(kp), ki: gain(ki), integ: clip(round(integ_ppb * 256))}

  defp gain(g),
    do: g |> Kernel.*(1 <<< @gain_frac) |> round() |> max(-(1 <<< 23)) |> min((1 <<< 23) - 1)

  @doc "The state with the integrator replaced by the raw output `integ` (the rate to continue from)."
  def preload(%__MODULE__{} = s, integ), do: %{s | integ: clip(integ)}

  @doc "Raw error input from ns (a number), saturated to s32."
  def err(ns), do: (ns * 256) |> round() |> max(-(1 <<< 31)) |> min((1 <<< 31) - 1)

  @doc "Raw error input from scaled ns (`ExPtp.Correction`)."
  def err_from_scaled(c), do: ((c + 128) >>> 8) |> max(-(1 <<< 31)) |> min((1 <<< 31) - 1)

  @doc "Raw output as ppb."
  def ppb(raw), do: raw / 256

  @doc "`{raw_output, next_state}` for the raw error `e`."
  def step(%__MODULE__{} = s, e) do
    integ = clip(s.integ - round_shift(s.ki * e))
    {clip(integ - round_shift(s.kp * e)), %{s | integ: integ}}
  end

  defp round_shift(x), do: (x + (1 <<< (@gain_frac - 1))) >>> @gain_frac
  defp clip(x), do: x |> max(@out_min) |> min(@out_max)
  def frac, do: @frac
end
