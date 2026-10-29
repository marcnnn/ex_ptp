defmodule ExPtp.Clock.System do
  @moduledoc """
  The operating system's clock (CLOCK_REALTIME) as a read-only `ExPtp.Clock`.
  Adjusting it needs `clock_adjtime` and CAP_SYS_TIME, which neither plain Erlang nor an
  unprivileged process has, so `adj_freq/2`, `step/2` and `set/2` return `{:error, :read_only}`
  and `caps/1` is empty. Use it as the observed clock of an `ExPtp.SoftServo` in `:monitor`
  mode (what ptp4l `free_running 1` does), or to compare a steered clock with the host's.
  A steerable clock without privileges is the software clock on top of CLOCK_REALTIME inside
  `ExPtp.Transport.Udp`.

  The handle is a keyword list; `:tai_offset_s` (default 0) is added to the reading, 37
  gives TAI like `ExPtp.Transport.Udp`.

      iex> {ExPtp.Clock.System, tai_offset_s: 37} |> ExPtp.Clock.now() |> is_struct(ExPtp.Timestamp)
      true
      iex> ExPtp.Clock.step({ExPtp.Clock.System, []}, 5)
      {:error, :read_only}
  """
  @behaviour ExPtp.Clock

  alias ExPtp.Timestamp

  @impl true
  def now(opts) do
    tai = Keyword.get(opts, :tai_offset_s, 0)
    Timestamp.from_ns(System.os_time(:nanosecond) + tai * 1_000_000_000)
  end

  @impl true
  def freq(_), do: 0.0
  @impl true
  def adj_freq(_, _), do: {:error, :read_only}
  @impl true
  def step(_, _), do: {:error, :read_only}
  @impl true
  def set(_, _), do: {:error, :read_only}
  @impl true
  def caps(_), do: []
end
