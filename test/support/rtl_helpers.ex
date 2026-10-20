defmodule ExPtp.Test.RTL do
  @moduledoc false
  alias ExHdl.RTL.{Cosim, Sim}

  @doc "BEAM simulation of `stim` (one input map per event; `rst_n` low for the first `resets`)."
  def beam(mod, stim, opts \\ []) do
    {_, out} = mod |> Sim.new(opts) |> Sim.run(stim)
    out
  end

  @doc "Idle input map of a module: every input 0."
  def idle(mod),
    do: for(p <- mod.ports, p.dir == :input, p.role != :clock, into: %{}, do: {p.name, 0})

  @doc "`n` reset events followed by `events` (each merged over `idle` with `rst_n: 1`)."
  def stimulus(mod, events, n \\ 2, extra \\ %{}) do
    base = mod |> idle() |> Map.merge(extra)

    List.duplicate(Map.put(base, :rst_n, 0), n) ++
      Enum.map(events, &(base |> Map.merge(&1) |> Map.put(:rst_n, 1)))
  end

  @doc "BEAM against Verilator on every output at every event."
  def cosim(mod, stim, opts \\ []), do: Cosim.assert_equivalent(mod, stim, opts)
end
