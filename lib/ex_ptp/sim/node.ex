defmodule ExPtp.Sim.Node do
  @moduledoc "`ExPtp.Transport` of a node in an `ExPtp.Sim` network; the handle is `{sim, node_id}`."
  @behaviour ExPtp.Transport

  @impl true
  def attach({sim, id}, pid), do: ExPtp.Sim.attach(sim, id, pid)
  @impl true
  def send_msg({sim, id}, channel, bin, opts), do: ExPtp.Sim.send_msg(sim, id, channel, bin, opts)
  @impl true
  def now({sim, id}), do: ExPtp.Sim.clock_now(sim, id)
  @impl true
  def schedule({sim, id}, delay_ns, msg), do: ExPtp.Sim.schedule(sim, id, delay_ns, msg)
  @impl true
  def adjust_frequency({sim, id}, ppb), do: ExPtp.Sim.adjust(sim, id, ppb)
  @impl true
  def step_clock({sim, id}, delta_ns), do: ExPtp.Sim.step(sim, id, delta_ns)
end
