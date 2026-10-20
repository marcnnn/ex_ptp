defmodule ExPtp.Test.Axis do
  @moduledoc false
  import Bitwise
  alias ExHdl.RTL.Sim

  @doc """
  Drives AXI4-Stream frames (binaries) into `s_axis` of `mod` in the BEAM
  simulator with random `tvalid` and `tready`, one event per cycle, and
  collects `m_axis`. Returns `%{frames, stim, log, accepted, cycles}`:
  `frames` has `%{data, out, cycle}` per output frame (`out` = all outputs at
  its last beat), `stim` replays the run in Verilator, `log` has the outputs
  of every cycle, `accepted` the input beats as `{cycle, frame, beat}`.

  Options: `bits:`, `seed:`, `valid_pct:`, `ready_pct:`, `user:` (frame index ->
  `s_axis_tuser` on the last beat), `extra:` (cycle, state with `acc` = input beats so far, newest first -> input map), `tail:`
  idle cycles before stopping, `max_cycles:`.
  """
  def drive(mod, frames, opts) do
    wb = div(Keyword.fetch!(opts, :bits), 8)
    :rand.seed(:exsss, {Keyword.get(opts, :seed, 1), 2, 3})
    user = Keyword.get(opts, :user, fn _ -> 0 end)

    beats =
      for {f, fi} <- Enum.with_index(frames),
          chunks = chunk(f, wb),
          {{data, len}, bi} <- Enum.with_index(chunks) do
        last = bi == length(chunks) - 1

        %{
          s_axis_tdata: data,
          s_axis_tkeep: (1 <<< len) - 1,
          s_axis_tlast: if(last, do: 1, else: 0),
          fi: fi,
          bi: bi,
          user: if(last, do: user.(fi), else: 0)
        }
      end

    ctx = %{
      idle: ExPtp.Test.RTL.idle(mod),
      vpct: Keyword.get(opts, :valid_pct, 100),
      rpct: Keyword.get(opts, :ready_pct, 100),
      extra: Keyword.get(opts, :extra, fn _, _ -> %{} end),
      tail: Keyword.get(opts, :tail, 24),
      max: Keyword.get(opts, :max_cycles, length(beats) * 80 + 400),
      has_user: Enum.any?(mod.ports, &(&1.name == :s_axis_tuser))
    }

    st = %{beats: beats, hold: false, cur: [], frames: [], log: [], stim: [], acc: [], quiet: 0}
    loop(Sim.new(mod), ctx, st, 0)
  end

  defp loop(sim, ctx, st, cycle) do
    reset = cycle < 2
    beat = List.first(st.beats)
    present = not reset and beat != nil and (st.hold or :rand.uniform(100) <= ctx.vpct)

    inputs =
      ctx.idle
      |> Map.merge(ctx.extra.(cycle, st))
      |> Map.put(:rst_n, if(reset, do: 0, else: 1))
      |> Map.put(:m_axis_tready, if(:rand.uniform(100) <= ctx.rpct, do: 1, else: 0))
      |> then(fn m ->
        if present do
          m
          |> Map.merge(Map.take(beat, [:s_axis_tdata, :s_axis_tkeep, :s_axis_tlast]))
          |> Map.put(:s_axis_tvalid, 1)
          |> then(&if(ctx.has_user, do: Map.put(&1, :s_axis_tuser, beat.user), else: &1))
        else
          m
        end
      end)

    sim = Sim.poke(sim, inputs)
    out = Sim.outputs(sim)
    taken = present and out.s_axis_tready == 1
    sent = not reset and out.m_axis_tvalid == 1 and inputs.m_axis_tready == 1

    st = %{
      st
      | beats: if(taken, do: tl(st.beats), else: st.beats),
        hold: present and not taken,
        acc: if(taken, do: [{cycle, beat.fi, beat.bi} | st.acc], else: st.acc),
        log: [out | st.log],
        stim: [inputs | st.stim],
        quiet:
          if(st.beats == [] and not sent and out.m_axis_tvalid == 0, do: st.quiet + 1, else: 0)
    }

    st =
      if sent do
        cur = [lanes(out.m_axis_tdata, out.m_axis_tkeep) | st.cur]

        if out.m_axis_tlast == 1 do
          data = cur |> Enum.reverse() |> IO.iodata_to_binary()
          %{st | cur: [], frames: [%{data: data, out: out, cycle: cycle} | st.frames]}
        else
          %{st | cur: cur}
        end
      else
        st
      end

    if st.quiet >= ctx.tail or cycle >= ctx.max do
      %{
        frames: Enum.reverse(st.frames),
        stim: Enum.reverse(st.stim),
        log: Enum.reverse(st.log),
        accepted: Enum.reverse(st.acc),
        cycles: cycle + 1
      }
    else
      loop(Sim.step(sim), ctx, st, cycle + 1)
    end
  end

  # the bytes of a beat selected by tkeep (contiguous from lane 0)
  defp lanes(data, keep) do
    n = Integer.digits(keep, 2) |> length()
    for i <- 0..(n - 1)//1, into: <<>>, do: <<data >>> (8 * i) &&& 0xFF>>
  end

  @doc "`[{beat_word, valid_bytes}]` for a frame, little endian lanes."
  def chunk(<<>>, _), do: []

  def chunk(frame, wb) do
    n = min(wb, byte_size(frame))
    <<c::binary-size(n), rest::binary>> = frame
    [{:binary.decode_unsigned(c, :little), n} | chunk(rest, wb)]
  end
end
