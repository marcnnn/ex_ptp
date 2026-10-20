defmodule ExPtp.RTL.ClosedLoopTest do
  use ExUnit.Case, async: true

  alias ExPtp.{Port, Servo, Sim}
  alias ExPtp.Servo.FixedPI
  alias ExPtp.Test.LoopBench

  @moduletag :verilator
  @moduletag timeout: 900_000

  @tick 240
  @intervals 70
  @interval_s 0.125

  # first index from which every later |offset| stays below `bound` (ns)
  defp settled(trace, bound) do
    Enum.find(0..(length(trace) - 1), fn i ->
      trace |> Enum.drop(i) |> Enum.all?(&(abs(&1) < bound))
    end)
  end

  # The recurrence the RTL implements, with a plain plant: offset grows by interval * (clock error + ppb).
  defp model_loop(o0, drift_ppb, n) do
    {kp, ki} = Servo.gains(-3)

    {rows, _, _} =
      Enum.reduce(0..(n - 1), {[], FixedPI.new(kp, ki), o0}, fn _, {acc, f, o} ->
        {raw, f} = FixedPI.step(f, FixedPI.err(o))
        {[{o, FixedPI.ppb(raw)} | acc], f, o + @interval_s * (drift_ppb + FixedPI.ppb(raw))}
      end)

    Enum.reverse(rows)
  end

  # Two Ports in the virtual time simulation with the same clocks, delays, jitter and tick; offsets per sync interval.
  defp beam_ports(n) do
    sim = Sim.start(seed: 7, delay_ns: 5_000, jitter_ns: 200)

    node = fn id, ident, nopts, opts ->
      t = Sim.add_node(sim, id, [tick_ns: @tick] ++ nopts)

      {:ok, pid} =
        Port.start_link([transport: t, clock_identity: <<ident::64>>, profile: :aes67] ++ opts)

      pid
    end

    node.(:m, 1, [drift_ppm: -20], clock_class: 6)

    s =
      node.(:s, 2, [drift_ppm: 50, initial_offset_ns: 3_000_000], clock_class: 248, servo: :fixed)

    trace =
      for _ <- 1..n do
        Sim.run_for(sim, 125_000_000)
        Sim.offset_ns(sim, :s, :m)
      end

    {trace, Port.info(s)}
  end

  test "two wallclocks on different clocks, servo and rate adjust in RTL: converges like the models" do
    r = LoopBench.run(intervals: @intervals, tick_ns: @tick)
    [cycles_m, cycles_s, stepped, dropped, exchanges, range_err] = r.done
    offs = for {_, o, _, _} <- r.trace, do: o
    ppbs = for {_, _, p, _} <- r.trace, do: p / 256
    locked_at = Enum.find_index(r.trace, fn {_, _, _, l} -> l end)

    # the clocks really differ: 4.2 MHz nominal, master 20 ppm slow, slave 50 ppm fast
    assert abs(cycles_s / cycles_m - 1.00007) < 2.0e-6
    assert stepped == 1 and dropped == 0 and range_err == 0
    assert exchanges >= @intervals

    # 1. against the recurrence of ExPtp.Servo.FixedPI (what the kernel is bit-identical to)
    model = model_loop(hd(offs), 70_000, length(offs))

    diffs = for {o, {m, _}} <- Enum.zip(offs, model), do: abs(o - m)

    IO.puts(
      "closed loop (#{@tick} ns tick, 70 ppm apart, 3 ms initial offset, #{@intervals} sync intervals of 125 ms):"
    )

    IO.puts(
      "  RTL vs FixedPI recurrence: max |difference| #{Float.round(Enum.max(diffs), 0)} ns over the run"
    )

    assert Enum.max(diffs) < 800

    # 2. convergence numbers, RTL and the Port based BEAM simulation of the same network
    {beam, info} = beam_ports(480)
    first_step = Enum.find_index(beam, &(abs(&1) < 100_000))
    beam_after = Enum.drop(beam, first_step)
    rtl_settle = settled(offs, 3_000)
    beam_settle = settled(beam_after, 3_000)
    tail = fn t -> t |> Enum.take(-10) |> Enum.map(&abs/1) |> Enum.max() end

    IO.puts(
      "  peak offset after the step: RTL #{Float.round(Enum.max(offs), 0)} ns, BEAM #{Float.round(Enum.max(beam_after) * 1.0, 0)} ns"
    )

    IO.puts(
      "  intervals until |offset| stays below 3 us: RTL #{rtl_settle}, BEAM #{beam_settle} (the Port run is slower: Delay_Req once a second with a filtered path delay, servo restarted after the step)"
    )

    IO.puts(
      "  |offset| over the last 10 intervals: RTL max #{Float.round(tail.(offs), 0)} ns, BEAM max #{Float.round(tail.(Enum.take(beam, -10)) * 1.0, 0)} ns"
    )

    IO.puts(
      "  servo frequency: RTL #{Float.round(List.last(ppbs), 1)} ppb, BEAM #{Float.round(info.freq_ppb, 1)} ppb, locked after #{locked_at} intervals"
    )

    assert rtl_settle < @intervals - 10
    assert rtl_settle <= beam_settle
    assert tail.(offs) < 500
    assert_in_delta List.last(ppbs), -70_000, 1_000
    assert_in_delta List.last(ppbs), info.freq_ppb, 1_500
    assert locked_at != nil
  end
end
