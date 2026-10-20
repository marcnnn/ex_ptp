defmodule ExPtp.ForeignMasters do
  @moduledoc """
  foreignMasterDS of one port with qualification (clause 9.3.2.5): a foreign
  master is qualified once `FOREIGN_MASTER_THRESHOLD` (2) Announce messages
  arrived within `FOREIGN_MASTER_TIME_WINDOW` (4 announce intervals). Records
  with `stepsRemoved >= 255`, from this clock itself, or with the
  alternateMaster flag are discarded.

  Times are local nanoseconds. Records hold the latest comparison data set
  (`ExPtp.BMCA.from_announce/2`) per sender.

      iex> alias ExPtp.{ForeignMasters, Message}
      iex> body = %{origin_timestamp: %ExPtp.Timestamp{}, current_utc_offset: 37, priority1: 128,
      ...>   clock_class: 6, clock_accuracy: 0x21, offset_scaled_log_variance: 0x4E5D, priority2: 128,
      ...>   grandmaster_identity: <<9::64>>, steps_removed: 0, time_source: 0x20}
      iex> msg = Message.new(:announce, {<<9::64>>, 1}, 1, body)
      iex> me = {<<1::64>>, 1}
      iex> fm = ForeignMasters.new(<<1::64>>, me, 4_000_000_000)
      iex> fm = ForeignMasters.add(fm, msg, 0)
      iex> ForeignMasters.qualified(fm, 10)
      []
      iex> fm = ForeignMasters.add(fm, %{msg | sequence_id: 2}, 1_000_000_000)
      iex> [%{grandmaster_identity: <<9::64>>}] = ForeignMasters.qualified(fm, 1_000_000_001)
      iex> ForeignMasters.qualified(fm, 9_000_000_000)
      []
  """
  alias ExPtp.{BMCA, Message}

  @threshold 2

  defstruct [:clock_identity, :port, :window_ns, records: %{}]

  @doc "Empty foreignMasterDS for the clock/port, with the qualification window in ns."
  def new(clock_identity, port, window_ns),
    do: %__MODULE__{clock_identity: clock_identity, port: port, window_ns: window_ns}

  @doc "Records an Announce received at local time `now_ns`."
  def add(%__MODULE__{} = fm, %Message{type: :announce, source: {cid, _} = sender} = msg, now_ns) do
    cond do
      cid == fm.clock_identity -> fm
      msg.body.steps_removed >= 255 -> fm
      Message.flag?(msg, :alternate_master) -> fm
      true -> store(fm, sender, msg, now_ns)
    end
  end

  def add(fm, _msg, _now), do: fm

  defp store(fm, sender, msg, now) do
    rec = Map.get(fm.records, sender, %{times: []})
    times = [now | Enum.filter(rec.times, &(now - &1 <= fm.window_ns))]
    data = BMCA.from_announce(msg, fm.port)
    %{fm | records: Map.put(fm.records, sender, %{times: times, data: data})}
  end

  @doc "Data sets of the qualified foreign masters at time `now_ns`."
  def qualified(%__MODULE__{} = fm, now_ns) do
    for {_, %{times: times, data: data}} <- fm.records,
        Enum.count(times, &(now_ns - &1 <= fm.window_ns)) >= @threshold,
        do: data
  end

  @doc "Erbest: the best qualified foreign master, or `nil`."
  def best(fm, now_ns), do: fm |> qualified(now_ns) |> BMCA.best()

  @doc "Forgets all records (announce receipt timeout)."
  def clear(fm), do: %{fm | records: %{}}

  @doc "Drops records with no Announce inside the window."
  def expire(fm, now_ns),
    do: %{
      fm
      | records:
          Map.filter(fm.records, fn {_, r} ->
            Enum.any?(r.times, &(now_ns - &1 <= fm.window_ns))
          end)
    }
end
