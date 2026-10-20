defmodule ExPtp.RTL.RxStampTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ExPtp.RTL.{Meta, PtpDetect, RxStamp}
  alias ExPtp.Test.{Axis, Frames}
  alias ExPtp.Test.RTL, as: T

  @wait 20
  @widths [8, 32, 64]

  defp ts_of(k), do: Meta.pack_ts({k + 1, 1000 + 7 * k, 3 * k})

  # Timestamp k is pushed shortly after frame k-1 was fully accepted (frame k then waits for it or
  # finds it queued); "late" ones come after the wait expired, in order.
  defp pusher(frames, modes, delays, bits) do
    n = length(frames)
    beats = Enum.map(frames, &length(Axis.chunk(&1, div(bits, 8))))

    fn cycle, st ->
      ends =
        for {c, fi, bi} <- st.acc, bi == Enum.at(beats, fi) - 1, into: %{}, do: {fi, c}

      times =
        Enum.reduce(0..(n - 1), %{}, fn k, acc ->
          base = if k == 0, do: 1, else: ends[k - 1]
          prev = Map.get(acc, k - 1, 0)

          if base && (k == 0 or prev != nil) do
            extra = if Enum.at(modes, k) == :late, do: @wait + 6, else: 0
            Map.put(acc, k, max(base + 1 + Enum.at(delays, k) + extra, prev + 1))
          else
            Map.put(acc, k, nil)
          end
        end)

      case Enum.find(0..(n - 1), &(times[&1] == cycle)) do
        nil -> %{}
        k -> %{ts_valid: 1, ts: ts_of(k)}
      end
    end
  end

  defp case_gen do
    gen all pairs <- StreamData.list_of(Frames.frame_gen(), min_length: 3, max_length: 10),
            seed <- StreamData.integer(1..1000),
            vpct <- StreamData.member_of([100, 50]),
            rpct <- StreamData.member_of([100, 40]),
            bits <- StreamData.member_of(@widths) do
      n = length(pairs)

      modes =
        for k <- 0..(n - 1), do: if(rem(k * 7 + seed, 5) == 0, do: :late, else: :ok)

      delays = for k <- 0..(n - 1), do: rem(k * 3 + seed, 7)
      {Enum.map(pairs, &elem(&1, 0)), modes, delays, seed, vpct, rpct, bits}
    end
  end

  defp run({frames, modes, delays, seed, vpct, rpct, bits}) do
    mod = RxStamp.build(bits, wait: @wait)

    res =
      Axis.drive(mod, frames,
        bits: bits,
        seed: seed,
        valid_pct: vpct,
        ready_pct: rpct,
        user: &if(rem(&1 + seed, 3) == 0, do: 1, else: 0),
        extra: pusher(frames, modes, delays, bits),
        tail: @wait + 30,
        max_cycles: 6000
      )

    {mod, res}
  end

  property "frames pass unchanged and carry timestamp, classification and bad flag in tuser" do
    check all(c <- case_gen(), max_runs: 25) do
      {frames, modes, _, seed, _, _, _} = c
      {_, res} = run(c)
      assert Enum.map(res.frames, & &1.data) == frames

      lost =
        for {{f, mode}, k} <- Enum.with_index(Enum.zip(frames, modes)), reduce: 0 do
          lost ->
            u = Meta.unpack_tuser(Enum.at(res.frames, k).out.m_axis_tuser)
            m = PtpDetect.classify(f)
            assert u.ptp == m.ptp and u.udp == m.udp, "frame #{k}"
            if m.ptp, do: assert(u.message_type == m.mtype)
            assert u.bad == (rem(k + seed, 3) == 0)

            if u.ts_valid do
              assert u.ts == ts_of(k)
              lost
            else
              assert mode == :late, "frame #{k} lost its timestamp"
              lost + 1
            end
        end

      assert Enum.count(res.log, &(&1.no_ts == 1)) == lost
      assert Enum.all?(res.log, &(&1.ts_overflow == 0))
    end
  end

  test "a timestamp that arrives after the wait is discarded and later frames stay aligned" do
    frames = for k <- 1..4, do: Frames.l2(:sync, [], k)
    modes = [:ok, :late, :ok, :ok]
    delays = [0, 0, 0, 0]
    {_, res} = run({frames, modes, delays, 5, 100, 100, 64})
    tuser = for f <- res.frames, do: Meta.unpack_tuser(f.out.m_axis_tuser)
    assert Enum.map(tuser, & &1.ts_valid) == [true, false, true, true]

    assert Enum.map(tuser, & &1.ts)
           |> Enum.with_index()
           |> Enum.filter(fn {_, k} -> k != 1 end)
           |> Enum.all?(fn {t, k} -> t == ts_of(k) end)

    assert Enum.count(res.log, &(&1.no_ts == 1)) == 1
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
