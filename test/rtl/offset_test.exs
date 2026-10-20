defmodule ExPtp.RTL.OffsetTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Bitwise

  alias ExPtp.RTL.{Meta, Offset}
  alias ExPtp.Test.RTL, as: T
  alias ExPtp.{Delay, Servo.FixedPI, Timestamp}

  @mod Offset.build()

  # a total in units of 2^-16 ns since the epoch as {sec, ns, frac16}
  defp ts(total) do
    ns_total = total >>> 16
    {div(ns_total, 1_000_000_000), rem(ns_total, 1_000_000_000), total &&& 0xFFFF}
  end

  defp exchange_gen do
    gen all sec <- StreamData.integer(10..1_000_000_000_000),
            ns <- StreamData.integer(0..999_999_999),
            frac <- StreamData.integer(0..0xFFFF),
            d1 <- StreamData.integer(0..40_000_000),
            d2 <- StreamData.integer(0..40_000_000),
            off <-
              StreamData.one_of([
                StreamData.integer(-(1 <<< 32)..(1 <<< 32)),
                StreamData.integer(-1_500_000_000..1_500_000_000)
              ]),
            turn <- StreamData.integer(0..5_000_000) do
      # scaled 2^-16 ns; `off` in ns*65536/16 steps of fraction
      base = ((sec * 1_000_000_000 + ns) <<< 16) + frac
      t1 = base
      t2 = base + (d1 <<< 16) + off * 4099
      t3 = t2 + (turn <<< 16)
      t4 = t3 - off * 4099 + (d2 <<< 16)
      [t1, t2, t3, t4] |> Enum.map(&ts/1) |> List.to_tuple()
    end
  end

  defp events(exs) do
    for {t1, t2, t3, t4} <- exs,
        ev <- [%{go: 1, t1: pk(t1), t2: pk(t2), t3: pk(t3), t4: pk(t4)}, %{}, %{}, %{}] do
      ev
    end
  end

  defp pk(t), do: Meta.pack_ts(t)

  property "err and mean path delay equal the model; valid two cycles after go" do
    check all(
            exs <- StreamData.list_of(exchange_gen(), min_length: 3, max_length: 12),
            max_runs: 40
          ) do
      out = T.beam(@mod, T.stimulus(@mod, events(exs))) |> Enum.drop(2)

      got = for o <- out, o.valid == 1, do: {o.err, o.mpd}
      assert got == Enum.map(exs, &Offset.model/1)
      # valid follows go by two cycles
      assert for({o, i} <- Enum.with_index(out), o.valid == 1, do: i) ==
               for(k <- 0..(length(exs) - 1), do: 4 * k + 2)
    end
  end

  property "the model is Delay.offset_from_master for whole-ns timestamps, FixedPI.err_from_scaled for the input" do
    check all(exs <- StreamData.list_of(exchange_gen(), min_length: 1, max_length: 6)) do
      for {t1, t2, t3, t4} <- exs do
        z = fn {s, n, _} -> {s, n, 0} end
        [a, b, c, d] = Enum.map([t1, t2, t3, t4], z)
        tt = fn {s, n, _} -> Timestamp.new(s, n) end
        mpd = Delay.e2e_mean_path_delay(tt.(a), tt.(b), tt.(c), tt.(d))
        off = Delay.offset_from_master(tt.(a), tt.(b), 0, mpd)
        assert Offset.model({a, b, c, d}) == {FixedPI.err_from_scaled(off), mpd}
      end
    end
  end

  test "a slave 1000 ns ahead, 500 ns each way" do
    t = &{0, &1, 0}

    stim =
      T.stimulus(@mod, [
        %{go: 1, t1: pk(t.(0)), t2: pk(t.(1500)), t3: pk(t.(2000)), t4: pk(t.(1500))},
        %{},
        %{}
      ])

    out = T.beam(@mod, stim) |> Enum.drop(2)
    o = Enum.find(out, &(&1.valid == 1))
    assert o.err == 1000 * 256
    assert o.mpd == 500 * 65536
  end

  @tag :verilator
  property "Verilator equals the BEAM simulator" do
    check all(
            exs <- StreamData.list_of(exchange_gen(), min_length: 3, max_length: 12),
            max_runs: 5
          ) do
      T.cosim(@mod, T.stimulus(@mod, events(exs)))
    end
  end
end
