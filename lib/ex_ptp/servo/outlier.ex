defmodule ExPtp.Servo.Outlier do
  @moduledoc """
  Rejects offset samples that are far outside what the recent samples looked
  like (a delayed packet with software timestamps). A sample is an outlier when
  `|offset|` exceeds `max(factor * median(recent |offset|), floor_ns)` once
  `min_samples` are known. After `max_run` rejections in a row the next sample is
  accepted, so a real phase change gets through. Rejected samples do not enter the window.

      iex> alias ExPtp.Servo.Outlier
      iex> o = Outlier.new(%{window: 8, factor: 4, floor_ns: 1000, min_samples: 3, max_run: 2})
      iex> o = Enum.reduce([100, -120, 90], o, fn x, o -> elem(Outlier.check(o, x), 1) end)
      iex> {v, o} = Outlier.check(o, 50_000)
      iex> v
      :reject
      iex> elem(Outlier.check(o, 110), 0)
      :ok
  """
  defstruct [:cfg, recent: [], run: 0]

  def new(cfg), do: %__MODULE__{cfg: cfg}

  @doc "`{:ok | :reject, filter}` for an offset in ns."
  def check(%__MODULE__{cfg: c} = f, off_ns) do
    a = abs(off_ns)
    n = length(f.recent)

    limit =
      if n >= c.min_samples, do: max(c.factor * median(f.recent), c.floor_ns), else: :infinity

    if limit != :infinity and a > limit and f.run < c.max_run do
      {:reject, %{f | run: f.run + 1}}
    else
      {:ok, %{f | recent: Enum.take([a | f.recent], c.window), run: 0}}
    end
  end

  defp median(list) do
    s = Enum.sort(list)
    Enum.at(s, div(length(s), 2))
  end
end
