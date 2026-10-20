defmodule ExPtp.RTL.PtpDetectTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExPtp.RTL.PtpDetect
  alias ExPtp.Test.{Axis, Benches, Frames}
  alias ExPtp.Test.RTL, as: T

  doctest PtpDetect

  @widths [8, 32, 64]

  defp frames_gen, do: StreamData.list_of(Frames.frame_gen(), min_length: 4, max_length: 14)

  defp run(bits, pairs, seed, vpct, rpct) do
    mod = Benches.detect_bench(bits)
    frames = Enum.map(pairs, &elem(&1, 0))
    res = Axis.drive(mod, frames, bits: bits, seed: seed, valid_pct: vpct, ready_pct: rpct)
    {mod, frames, res}
  end

  # classification after the last beat of each frame was accepted
  defp seen(res, frames) do
    for {f, fi} <- Enum.with_index(frames) do
      {c, _, _} = res.accepted |> Enum.filter(&(elem(&1, 1) == fi)) |> List.last()
      {f, Enum.at(res.log, c + 1)}
    end
  end

  defp agree(f, out) do
    m = PtpDetect.classify(f)
    assert out.ptp == b(m.ptp), "ptp #{inspect(m)} #{inspect(out)}"
    assert out.udp == b(m.udp)
    assert out.ev_port == b(m.ev_port)
    if m.ptp, do: assert({out.mtype, out.ptp_off} == {m.mtype, m.ptp_off})
    if m.ev_port or m.l4_off > 0, do: assert(out.l4_off == m.l4_off)
  end

  defp b(true), do: 1
  defp b(false), do: 0

  property "the Elixir model decides like the specification on generated frames" do
    check all(pairs <- frames_gen()) do
      for {f, truth} <- pairs, truth != :runt do
        m = PtpDetect.classify(f)
        t = Frames.truth(truth)
        assert m.ptp == t.ptp and m.udp == t.udp, inspect({truth, m})
        if t.ptp, do: assert(m.mtype == t.mtype)
      end
    end
  end

  for bits <- @widths do
    property "#{bits} bit stream: RTL (BEAM) equals the model for every frame, random stalls" do
      bits = unquote(bits)

      check all(
              pairs <- frames_gen(),
              seed <- StreamData.integer(1..1000),
              vpct <- StreamData.member_of([100, 60, 25]),
              rpct <- StreamData.member_of([100, 50]),
              max_runs: 12
            ) do
        {_, frames, res} = run(bits, pairs, seed, vpct, rpct)
        for {f, out} <- seen(res, frames), do: agree(f, out)
        # the passthrough keeps the bytes
        assert Enum.map(res.frames, & &1.data) == frames
      end
    end
  end

  @tag :verilator
  @tag timeout: 300_000
  property "Verilator equals the BEAM simulator" do
    check all(
            bits <- StreamData.member_of(@widths),
            pairs <- frames_gen(),
            seed <- StreamData.integer(1..1000),
            max_runs: 4
          ) do
      {mod, _, res} = run(bits, pairs, seed, 70, 60)
      T.cosim(mod, res.stim)
    end
  end
end
