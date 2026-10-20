defmodule ExPtp.Servo.Lock do
  @moduledoc """
  Lock detection with hysteresis: locked after `count` consecutive offsets
  within `threshold_ns`, unlocked as soon as one exceeds `unlock_factor *
  threshold_ns`.

      iex> alias ExPtp.Servo.Lock
      iex> l = Lock.new(100, 3)
      iex> l = Enum.reduce([50, -20, 10], l, &Lock.update(&2, &1))
      iex> l.locked
      true
      iex> Lock.update(l, 500).locked
      false
  """
  defstruct [:threshold_ns, :needed, unlock_factor: 2, run: 0, locked: false]

  def new(threshold_ns, needed, unlock_factor \\ 2),
    do: %__MODULE__{threshold_ns: threshold_ns, needed: needed, unlock_factor: unlock_factor}

  @doc "Feeds one offset (ns)."
  def update(%__MODULE__{} = l, offset_ns) do
    a = abs(offset_ns)

    cond do
      a <= l.threshold_ns ->
        run = l.run + 1
        %{l | run: run, locked: l.locked or run >= l.needed}

      a > l.threshold_ns * l.unlock_factor ->
        %{l | run: 0, locked: false}

      true ->
        %{l | run: 0}
    end
  end
end
