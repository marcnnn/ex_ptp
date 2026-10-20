defmodule ExPtp.Sim do
  @moduledoc """
  Discrete-event simulation of a PTP network in virtual time, for testing
  ports against each other. All nodes share one broadcast domain (a switch
  that floods every packet); each ordered pair of nodes has its own link
  delay, so asymmetry is a setting. Every node has a local clock with a
  constant frequency error (`drift_ppb`), a rate adjustment set by its
  servo, a timestamp granularity and optional timestamp noise.

  The simulation is driven by the caller: `run_for/2` pops events in time
  order and delivers each to the owning process, waiting until the process
  has handled it, so runs are deterministic for a given seed. Nodes are
  `{ExPtp.Sim.Node, handle}` transports for `ExPtp.Port`.

      sim = ExPtp.Sim.start(seed: 1, delay_ns: 5_000, jitter_ns: 200)
      node = ExPtp.Sim.add_node(sim, :a, drift_ppb: 20_000)
      {:ok, _} = ExPtp.Port.start_link(transport: node, clock_identity: <<1::64>>)
      ExPtp.Sim.run_for(sim, 10_000_000_000)

  Link options: `:delay_ns`, `:jitter_ns` (uniform extra delay in
  `[0, jitter_ns]`), `:loss` (probability 0.0..1.0).
  """
  alias ExPtp.{Message, Timestamp}

  @ns 1_000_000_000
  @default_link %{delay_ns: 0, jitter_ns: 0, loss: 0.0}

  @doc """
  Starts a simulation (an `Agent`). Options: `:seed`, `:start_ns` (true time,
  default 1000 s), and the default link options.
  """
  def start(opts \\ []) do
    {:ok, pid} =
      Agent.start_link(fn ->
        {seed, opts} = Keyword.pop(opts, :seed, 1)
        {start, opts} = Keyword.pop(opts, :start_ns, 1000 * @ns)

        %{
          t: start,
          seq: 0,
          queue: :gb_trees.empty(),
          nodes: %{},
          links: %{},
          default_link: Map.merge(@default_link, Map.new(opts)),
          rng: :rand.seed_s(:exsss, {seed, seed + 1, seed + 2})
        }
      end)

    pid
  end

  @doc """
  Adds a node and returns its transport. Options: `:drift_ppb` (or
  `:drift_ppm`), `:initial_offset_ns` (local clock minus true time),
  `:tick_ns` (timestamp granularity, default 8), `:ts_noise_ns` (uniform
  timestamp noise `+-`, default 0).
  """
  def add_node(sim, id, opts \\ []) do
    Agent.update(sim, fn s ->
      drift = opts[:drift_ppb] || round((opts[:drift_ppm] || 0) * 1000)

      node = %{
        t0: s.t,
        l0: s.t + (opts[:initial_offset_ns] || 0),
        drift: drift,
        adj: 0,
        tick: opts[:tick_ns] || 8,
        noise: opts[:ts_noise_ns] || 0,
        owner: nil
      }

      put_in(s.nodes[id], node)
    end)

    {ExPtp.Sim.Node, {sim, id}}
  end

  @doc "Sets options of the link `from -> to`."
  def set_link(sim, from, to, opts),
    do:
      Agent.update(sim, fn s ->
        put_in(s.links[{from, to}], Map.merge(link(s, from, to), Map.new(opts)))
      end)

  @doc "Changes a node's frequency error at the current time."
  def set_drift(sim, id, drift_ppb),
    do: Agent.update(sim, &update_node(&1, id, fn n -> %{n | drift: drift_ppb} end))

  @doc "True simulation time in ns."
  def now(sim), do: Agent.get(sim, & &1.t)

  @doc "A node's local clock in ns at the current time."
  def local_ns(sim, id), do: Agent.get(sim, &local(&1.nodes[id], &1.t))

  @doc "Local clock of `a` minus that of `b`, ns."
  def offset_ns(sim, a, b),
    do: Agent.get(sim, &(local(&1.nodes[a], &1.t) - local(&1.nodes[b], &1.t)))

  @doc "Runs for `ns` of true time."
  def run_for(sim, ns), do: run_until(sim, now(sim) + ns)

  @doc "Runs until true time `t_end`, delivering all events up to then."
  def run_until(sim, t_end) do
    case Agent.get_and_update(sim, &pop(&1, t_end)) do
      :none ->
        Agent.update(sim, &%{&1 | t: max(&1.t, t_end)})

      {owner, msg} ->
        send(owner, msg)
        barrier(owner)
        run_until(sim, t_end)
    end
  end

  defp barrier(pid) do
    :sys.get_state(pid, 10_000)
  catch
    :exit, _ -> :ok
  end

  # -- node side (used by ExPtp.Sim.Node) ------------------------------------------------------

  @doc false
  def attach(sim, id, pid),
    do: Agent.update(sim, &update_node(&1, id, fn n -> %{n | owner: pid} end))

  @doc false
  def clock_now(sim, id),
    do: Agent.get(sim, &(&1.nodes[id] |> local(&1.t) |> Timestamp.from_ns()))

  @doc false
  def adjust(sim, id, ppb),
    do: Agent.update(sim, &update_node(&1, id, fn n -> %{n | adj: round(ppb)} end))

  @doc false
  def step(sim, id, delta_ns),
    do: Agent.update(sim, &update_node(&1, id, fn n -> %{n | l0: n.l0 + delta_ns} end))

  @doc false
  def schedule(sim, id, delay_ns, msg) do
    Agent.update(sim, fn s ->
      rate = @ns + s.nodes[id].drift + s.nodes[id].adj
      true_delay = div(delay_ns * @ns, rate)
      enqueue(s, s.t + true_delay, {:timer, id, msg})
    end)
  end

  @doc false
  def send_msg(sim, id, channel, bin, opts) do
    Agent.get_and_update(sim, fn s ->
      {tx, s} = stamp(s, id)
      bin = if opts[:one_step], do: patch_origin(bin, tx), else: bin

      s =
        for {to, _} <- s.nodes, to != id, reduce: s do
          s ->
            link = link(s, id, to)
            {lost, s} = uniform(s, 1_000_000)
            {extra, s} = uniform(s, link.jitter_ns + 1)

            if lost < link.loss * 1_000_000,
              do: s,
              else: enqueue(s, s.t + link.delay_ns + extra, {:rx, to, channel, bin})
        end

      {{:ok, if(channel == :event, do: tx)}, s}
    end)
  end

  # -- internals ----------------------------------------------------------------------------

  defp link(s, from, to), do: Map.get(s.links, {from, to}, s.default_link)

  defp update_node(s, id, fun) do
    n = s.nodes[id]
    n = %{n | l0: local(n, s.t), t0: s.t}
    put_in(s.nodes[id], fun.(n))
  end

  defp local(n, t),
    do: n.l0 + (t - n.t0) + Integer.floor_div((t - n.t0) * (n.drift + n.adj), @ns)

  # Hardware timestamp: granularity of the node's clock, plus noise.
  defp stamp(s, id) do
    n = s.nodes[id]
    l = local(n, s.t)
    {noise, s} = if n.noise > 0, do: uniform(s, 2 * n.noise + 1), else: {n.noise, s}
    {Timestamp.from_ns(Integer.floor_div(l, n.tick) * n.tick + noise - n.noise), s}
  end

  defp uniform(s, n) do
    {v, rng} = :rand.uniform_s(n, s.rng)
    {v - 1, %{s | rng: rng}}
  end

  defp enqueue(s, time, event) do
    %{s | queue: :gb_trees.insert({time, s.seq}, event, s.queue), seq: s.seq + 1}
  end

  defp pop(s, t_end) do
    if :gb_trees.is_empty(s.queue) do
      {:none, s}
    else
      {{time, _}, event, rest} = :gb_trees.take_smallest(s.queue)

      if time > t_end do
        {:none, s}
      else
        s = %{s | queue: rest, t: max(s.t, time)}
        deliver(s, event)
      end
    end
  end

  defp deliver(s, {:timer, id, msg}),
    do: {{s.nodes[id].owner, {:ptp_timer, msg}}, s}

  defp deliver(s, {:rx, id, channel, bin}) do
    {rx, s} = if channel == :event, do: stamp(s, id), else: {nil, s}
    {{s.nodes[id].owner, {:ptp_rx, channel, bin, rx}}, s}
  end

  defp patch_origin(bin, tx) do
    case Message.decode(bin) do
      {:ok, %{body: %{origin_timestamp: _} = b} = m} ->
        Message.encode(%{m | body: %{b | origin_timestamp: tx}})

      _ ->
        bin
    end
  end
end
