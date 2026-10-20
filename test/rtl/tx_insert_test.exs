defmodule ExPtp.RTL.TxInsertTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Bitwise

  alias ExPtp.RTL.TxInsert
  alias ExPtp.Test.{Axis, Benches, Frames}
  alias ExPtp.Test.RTL, as: T

  doctest TxInsert

  @widths [8, 32, 64]

  defp sync_frame_gen do
    gen all kind <- StreamData.member_of([:l2, :udp]),
            tags <- StreamData.list_of(StreamData.member_of([0x8100, 0x88A8]), max_length: 2),
            seq <- StreamData.integer(0..0xFFFF) do
      if kind == :l2, do: Frames.l2(:sync, tags, seq), else: Frames.over_udp(:sync, tags, seq)
    end
  end

  defp frames_gen do
    StreamData.list_of(
      StreamData.frequency([
        {3, sync_frame_gen()},
        {2, StreamData.map(Frames.frame_gen(), &elem(&1, 0))}
      ]),
      min_length: 3,
      max_length: 10
    )
  end

  defp case_gen do
    gen all frames <- frames_gen(),
            bits <- StreamData.member_of(@widths),
            seed <- StreamData.integer(1..1000),
            vpct <- StreamData.member_of([100, 50]),
            rpct <- StreamData.member_of([100, 40]),
            enable <- StreamData.member_of([true, true, false]),
            zero <- StreamData.boolean(),
            comp <- StreamData.integer(0..(1 <<< 24)),
            sec <- StreamData.integer(1..100_000),
            ns <- StreamData.integer(999_999_700..999_999_999) do
      %{
        frames: frames,
        bits: bits,
        seed: seed,
        vpct: vpct,
        rpct: rpct,
        enable: enable,
        zero: zero,
        comp: comp,
        sec: sec,
        ns: ns
      }
    end
  end

  defp run(c) do
    mod = Benches.tx_bench(c.bits)

    extra = fn cycle, _ ->
      base = %{enable: b(c.enable), zero_csum: b(c.zero), comp: c.comp}
      if cycle == 2, do: Map.merge(base, %{set_wr: 1, set_sec: c.sec, set_ns: c.ns}), else: base
    end

    # the clock is set at cycle 2; the first frame starts later
    res =
      Axis.drive(mod, c.frames,
        bits: c.bits,
        seed: c.seed,
        valid_pct: c.vpct,
        ready_pct: c.rpct,
        extra: extra,
        tail: 40
      )

    {mod, res}
  end

  defp b(true), do: 1
  defp b(false), do: 0

  defp verify(c, res) do
    assert length(res.frames) == length(c.frames)

    for {f, k} <- Enum.with_index(c.frames) do
      {c0, _, _} = Enum.find(res.accepted, fn {_, fi, bi} -> fi == k and bi == 0 end)
      o = Enum.at(res.log, c0)

      expect =
        TxInsert.apply_model(f, {o.now_sec, o.now_ns, o.now_frac}, c.comp, c.enable, c.zero)

      got = Enum.at(res.frames, k)
      assert got.data == expect, "frame #{k}"
      modified = expect != f
      # `stamped` pulses once per frame whose origin timestamp was written
      assert Enum.at(res.log, got.cycle + 1).stamped == 1 == (modified and ts_written?(f, c))
    end
  end

  defp ts_written?(f, c) do
    i = ExPtp.RTL.PtpDetect.classify(f)
    c.enable and i.ptp and i.mtype == 0 and byte_size(f) > i.ptp_off + 34
  end

  property "origin timestamp and checksum edits match the model on every frame, any stalls" do
    check all(c <- case_gen(), max_runs: 25) do
      {_, res} = run(c)
      verify(c, res)
    end
  end

  test "a one-step Sync over UDP: timestamp in place, checksum zero, the rest untouched" do
    f = Frames.over_udp(:sync, [0x8100], 9)

    c = %{
      frames: [<<1, 2, 3>>, f],
      bits: 64,
      seed: 1,
      vpct: 100,
      rpct: 100,
      enable: true,
      zero: true,
      comp: 65_536 * 100,
      sec: 77,
      ns: 999_999_900
    }

    {_, res} = run(c)
    [_, out] = res.frames
    assert byte_size(out.data) == byte_size(f)
    o = 14 + 4 + 20 + 8 + 34
    <<pre::binary-size(o), sec::48, ns::32, post::binary>> = out.data
    <<fpre::binary-size(o), _::80, fpost::binary>> = f
    assert sec == 78 or sec == 77
    assert ns < 1000 or ns > 999_999_900
    # checksum zeroed, everything else equal
    cs = 14 + 4 + 20 + 6
    <<a::binary-size(cs), 0, 0, b::binary>> = pre
    <<fa::binary-size(cs), _::16, fb::binary>> = fpre
    assert {a, b, post} == {fa, fb, fpost}
    assert Enum.at(res.log, out.cycle + 1).stamped == 1
  end

  @tag :verilator
  @tag timeout: 300_000
  property "Verilator equals the BEAM simulator" do
    check all(c <- case_gen(), max_runs: 4) do
      {mod, res} = run(c)
      T.cosim(mod, res.stim)
    end
  end
end
