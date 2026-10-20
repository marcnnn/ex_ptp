defmodule ExPtp.BMCA do
  @moduledoc """
  Best master clock algorithm (IEEE 1588-2019 clause 9.3): the data set
  comparison (`compare/2`, including the topology part 2) and the state
  decision algorithm for an ordinary clock (`state_decision/4`).

  A comparison data set is a map built by `from_announce/2` (a received
  Announce, with the identity of the receiving port) or `from_default/2` (the
  clock's own defaultDS, D0): `priority1`, `clock_class`, `clock_accuracy`,
  `offset_scaled_log_variance`, `priority2`, `grandmaster_identity`,
  `steps_removed`, `sender` and `receiver` (port identities).

      iex> alias ExPtp.{BMCA, DataSets.Default}
      iex> a = Default.new(<<1, 0, 0, 0, 0, 0, 0, 1>>, clock_class: 6) |> BMCA.from_default(1)
      iex> b = Default.new(<<1, 0, 0, 0, 0, 0, 0, 2>>, clock_class: 248) |> BMCA.from_default(1)
      iex> BMCA.compare(a, b)
      {:a, :dataset}
      iex> BMCA.state_decision(a, b, :listening, false)
      :m1
      iex> BMCA.state_decision(b, a, :listening, false)
      :s1
  """
  alias ExPtp.DataSets.Default

  @type dataset :: map()
  @type decision :: :listening | :m1 | :m2 | :s1 | :p1 | :p2

  @doc "D0: the clock's own defaultDS as a comparison data set for port `port_number`."
  def from_default(%Default{} = d, port_number) do
    me = {d.clock_identity, port_number}

    %{
      priority1: d.priority1,
      clock_class: d.clock_quality.clock_class,
      clock_accuracy: d.clock_quality.clock_accuracy,
      offset_scaled_log_variance: d.clock_quality.offset_scaled_log_variance,
      priority2: d.priority2,
      grandmaster_identity: d.clock_identity,
      steps_removed: 0,
      sender: me,
      receiver: me
    }
  end

  @doc "Comparison data set of an Announce message received on port `receiver`."
  def from_announce(%ExPtp.Message{type: :announce, body: b, source: sender} = msg, receiver) do
    %{
      priority1: b.priority1,
      clock_class: b.clock_class,
      clock_accuracy: b.clock_accuracy,
      offset_scaled_log_variance: b.offset_scaled_log_variance,
      priority2: b.priority2,
      grandmaster_identity: b.grandmaster_identity,
      steps_removed: b.steps_removed,
      sender: sender,
      receiver: receiver,
      announce: msg
    }
  end

  @fields [
    :priority1,
    :clock_class,
    :clock_accuracy,
    :offset_scaled_log_variance,
    :priority2,
    :grandmaster_identity
  ]

  @doc """
  Compares two data sets. Returns `{:a | :b, :dataset | :topology}` for the
  better one (and whether the grandmaster data or only the path decided), or
  `:equal` when both describe the same port (clause 9.3.4 "error-1/2").
  Lower values win everywhere.
  """
  def compare(a, b) do
    if a.grandmaster_identity == b.grandmaster_identity do
      topology(a, b)
    else
      case Enum.find_value(@fields, fn f -> cmp(a[f], b[f]) end) do
        :lt -> {:a, :dataset}
        :gt -> {:b, :dataset}
      end
    end
  end

  defp cmp(x, x), do: nil
  defp cmp(x, y), do: if(x < y, do: :lt, else: :gt)

  # Figure 35: same grandmaster, decide on the path.
  defp topology(a, b) do
    cond do
      a.steps_removed + 1 < b.steps_removed ->
        {:a, :dataset}

      b.steps_removed + 1 < a.steps_removed ->
        {:b, :dataset}

      a.steps_removed > b.steps_removed ->
        by_ports(a.receiver, a.sender, :b)

      a.steps_removed < b.steps_removed ->
        by_ports(b.receiver, b.sender, :a)

      true ->
        case cmp(a.sender, b.sender) || cmp(a.receiver, b.receiver) do
          :lt -> {:a, :topology}
          :gt -> {:b, :topology}
          nil -> :equal
        end
    end
  end

  # The longer path loses; it loses "by topology" if its receiver is above its sender.
  defp by_ports(receiver, sender, winner) do
    case cmp(receiver, sender) do
      :lt -> {winner, :dataset}
      :gt -> {winner, :topology}
      nil -> :equal
    end
  end

  @doc "The better of a list of data sets (`nil` for an empty list); ties keep the first."
  def best([]), do: nil

  def best([first | rest]),
    do:
      Enum.reduce(rest, first, fn d, best ->
        case compare(d, best) do
          {:a, _} -> d
          _ -> best
        end
      end)

  @doc """
  State decision (figure 26) for a clock with one port. `d0` is the own
  data set, `erbest` the best qualified foreign master (or `nil`).
  `:m1`/`:m2` become master, `:s1` slave, `:p1`/`:p2` passive;
  `:listening` means no decision (nothing qualified yet).
  """
  def state_decision(_d0, nil, :listening, _slave_only), do: :listening

  def state_decision(d0, nil, _state, _slave_only),
    do: if(d0.clock_class <= 127, do: :m1, else: :m2)

  def state_decision(d0, erbest, _state, _slave_only) do
    d0_wins = match?({:a, _}, compare(d0, erbest))

    cond do
      d0.clock_class <= 127 -> if d0_wins, do: :m1, else: :p1
      d0_wins -> :m2
      true -> :s1
    end
  end
end
