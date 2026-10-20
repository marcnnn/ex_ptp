defmodule ExPtp.RTL.Offset do
  @moduledoc """
  Offset from master of one delay request-response exchange, in hardware:
  `ExPtp.Delay.e2e_mean_path_delay/6` and `offset_from_master/4` with zero
  corrections, on timestamps of 94 bits (`ExPtp.RTL.Meta`: seconds, ns,
  fraction in 2^-16 ns).

      d12 = t2 - t1,  d43 = t4 - t3                 (scaled ns, 2^-16)
      mpd = (d12 + d43) >> 1                        (arithmetic shift)
      offset = d12 - mpd
      err = saturate_s32((offset + 128) >> 8)       (ns with 8 fractional bits)

  `err` is what `ExPtp.RTL.Servo` takes (`ExPtp.Servo.FixedPI.err_from_scaled/1`).
  Timestamps may differ by up to +-1 second (the differences are formed on
  the second counters modulo 8, then scaled); offsets and delays beyond
  that are not meaningful for a servo anyway.

  Ports (domain `:sys`): `go` (strobe; the `t1..t4` inputs are read on that
  cycle), outputs `valid` (one cycle, 2 cycles after `go`), `err` (s32),
  `mpd` (s48, scaled ns, the mean path delay of this exchange).
  `model/1` is the Elixir version.
  """
  use ExHdl.RTL
  import Bitwise

  @unit 1_000_000_000 <<< 16

  @doc "`{err, mpd}` for four `{sec, ns, frac16}` tuples."
  def model({t1, t2, t3, t4}) do
    d12 = scaled(t2) - scaled(t1)
    d43 = scaled(t4) - scaled(t3)
    mpd = (d12 + d43) >>> 1
    off = d12 - mpd
    {((off + 128) >>> 8) |> max(-(1 <<< 31)) |> min((1 <<< 31) - 1), mpd}
  end

  defp scaled({s, n, f}), do: ((s * 1_000_000_000 + n) <<< 16) + f

  def build do
    module "ptp_offset" do
      go = input(:go, 1)
      ts = for n <- [:t1, :t2, :t3, :t4], do: {n, input(n, 94)}
      valid = output(:valid, 1, reset: 0)
      err = output(:err, s(32), reset: 0)
      mpd_o = output(:mpd, s(48), reset: 0)

      d12 = reg(:d12, s(50), reset: nil)
      d43 = reg(:d43, s(50), reset: nil)
      v1 = reg(:v1, 1)

      # scaled difference of two timestamps: whole seconds (mod 8) times 10^9 * 2^16 plus the rest
      diff = fn a, b ->
        ds = as_signed(trunc(sub_wrap(a[46..93], b[46..93]), 3))
        rest = to_signed(a[0..45]) - to_signed(b[0..45])
        ds * const(@unit, s(48)) + rest
      end

      [t1, t2, t3, t4] = Enum.map(ts, &elem(&1, 1))
      sum = wire(:sum, d12 + d43)
      mpd = wire(:mpd_w, sum >>> 1)
      ofs = wire(:ofs, d12 - mpd)
      scaled = wire(:scaled, (ofs + 128) >>> 8)
      hi = 1 <<< 31

      sync do
        v1 <~ go
        valid <~ v1

        if go do
          d12 <~ trunc(diff.(t2, t1), 50)
          d43 <~ trunc(diff.(t4, t3), 50)
        end

        if v1 do
          mpd_o <~ trunc(mpd, 48)

          err
          <~ mux(
            scaled > hi - 1,
            const(hi - 1, s(32)),
            mux(scaled < -hi, const(-hi, s(32)), trunc(scaled, 32))
          )
        end
      end
    end
  end
end
