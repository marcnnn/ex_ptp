defmodule ExPtp.Servo.PI do
  @moduledoc """
  Float64 PI servo, the same recurrence as `ExPtp.Servo.pi_step/5` with the
  output clamped to `+-max_ppb`.

      iex> s = ExPtp.Servo.PI.new(0.7, 0.3)
      iex> {out, _} = ExPtp.Servo.PI.step(s, 1000.0)
      iex> out
      -1000.0
  """
  defstruct [:kp, :ki, integ: 0.0, max_ppb: 524_288.0]

  @doc "Servo with gains `kp`, `ki`; option `:max_ppb`."
  def new(kp, ki, opts \\ []), do: struct!(%__MODULE__{kp: kp, ki: ki}, opts)

  @doc "`{ppb, next_state}` for an offset of `err_ns`."
  def step(%__MODULE__{} = s, err_ns) do
    integ = clamp(s.integ - s.ki * err_ns, s.max_ppb)
    {clamp(integ - s.kp * err_ns, s.max_ppb), %{s | integ: integ}}
  end

  defp clamp(x, m), do: x |> max(-m) |> min(m)
end
