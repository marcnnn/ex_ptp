defmodule ExPtp.RTL.MediaNco do
  @moduledoc """
  Media clock in hardware: a phase accumulator that produces the sample
  tick and the RTP timestamp, aligned to the PTP epoch (AES67 clause 8:
  `rtp = floor(t * rate) + offset mod 2^32`, `ExPtp.MediaClock`).

  ## Free running part (`ExPtp.MediaClock.Nco`, bit-exact)

  Every cycle `{carry, phase} = phase + inc` (64 bit). `tick` is high for
  one cycle after a carry, with `rtp_ts` already incremented in that cycle
  (`rtp_ts` = number of ticks since the last alignment plus its base).
  `inc = rate / f_clk * 2^64`: `Nco.increment/3` (written with `inc_wr`,
  `inc_in`), or in `follow` mode derived from the wallclock's increment so
  the media clock moves with every rate correction the servo makes:
  `inc = floor(wc_inc * kscale / 2^24)`, `kscale = kscale(rate)`
  (`follow_inc/2`). Two cycles of delay behind a change of `wc_inc`.

  `mclk_en` is high for one cycle whenever the top `mclk_log2` (default 8)
  phase bits change: `2^mclk_log2 * fs` enables per second, phase locked to
  `tick`, exactly 256 per sample. It is a clock enable (jitter one `clk`
  period), not a clock.

  ## Alignment to the wallclock

  `align` (strobe, ignored while `busy`) latches the wallclock and computes,
  exactly and with a sequential divider (18 + 64 cycles, no DSP in the
  loop), the sample count `floor(t * rate)` and the phase
  `frac(t * rate) * 2^64` for `t = seconds + (ns + frac / 2^32)` ns, then
  loads the accumulator with the value advanced by the cycles the
  computation took, so that from the cycle `aligned` pulses, `rtp_ts` and
  `phase` match the wallclock reading of the same cycle (`ideal/4`).
  `rate` (u18) and `offset` (u32) must be stable from `align` until
  `aligned`. The model rounds `t` down to whole ns, the hardware keeps the
  32-bit fraction: the two `rtp_ts` can differ by one where `t * rate` is within
  `rate * 2^-32` of an integer.

  Align once after start, after a wallclock `step_wr`/`set_wr`, and now and
  then (once per second is plenty) to remove the drift of the quantised
  `inc`. A slew changes the wallclock rate for a while, not `inc`: follow
  mode covers the servo's rate, a following `align` the rest.
  """
  use ExHdl.RTL
  import Bitwise
  alias ExPtp.RTL.Ifc

  @ns 1_000_000_000
  @m @ns <<< 32

  @doc "`kscale` input for `follow` mode."
  def kscale(rate), do: div(rate * (1 <<< 56) + div(@ns, 2), @ns)

  @doc "NCO increment derived from a wallclock increment, as the hardware does."
  def follow_inc(wc_inc, rate), do: (wc_inc * kscale(rate)) >>> 24

  @doc """
  The ideal 96 bit fixed point media time `{rtp::32, phase::64}` for a wallclock
  reading `{sec, ns, frac32}`: what `rtp_ts` and `phase` equal after alignment, up to the rounding of `inc`.

      iex> ExPtp.RTL.MediaNco.ideal({1, 0, 0}, 48_000, 5) |> Bitwise.bsr(64)
      48_005
  """
  def ideal({sec, ns, frac}, rate, offset) do
    t = ((sec * @ns + ns) <<< 32) + frac
    div((t * rate) <<< 64, @m) + (offset <<< 64) &&& (1 <<< 96) - 1
  end

  def build(mclk_log2 \\ 8) do
    module "ptp_media_nco_m#{mclk_log2}" do
      now_sec = input(:now_sec, 48)
      now_ns = input(:now_ns, 32)
      now_frac = input(:now_frac, 32)
      rate = input(:rate, 18)
      offset = input(:offset, 32)
      inc_wr = input(:inc_wr, 1)
      inc_in = input(:inc_in, 64)
      follow = input(:follow, 1)
      wc_inc = input(:wc_inc, 40)
      kscale = input(:kscale, 56)
      align = input(:align, 1)

      %{tick: tick, rtp_ts: rtp} = Ifc.media_clock(:master, reset: 0)
      mclk_en = output(:mclk_en, 1, reset: 0)
      phase_o = output(:phase, 64)
      busy_o = output(:busy, 1)
      aligned = output(:aligned, 1, reset: 0)

      phase = reg(:ph, 64)
      inc = reg(:inc, 64)
      inc_f = reg(:inc_f, 64)
      fprod = reg(:fprod, 96, reset: nil)

      st = reg(:st, 3)
      cnt = reg(:cnt, 7)
      elapsed = reg(:elapsed, 8)
      a_sec = reg(:a_sec, 32, reset: nil)
      a_t = reg(:a_t, 62, reset: nil)
      x = reg(:x, 80, reset: nil)
      sr = reg(:sr, 32, reset: nil)
      rem = reg(:rem, 62, reset: nil)
      xs = reg(:xs, 18, reset: nil)
      qacc = reg(:qacc, 18, reset: nil)
      pacc = reg(:pacc, 64, reset: nil)
      prod = reg(:prod, 73, reset: nil)

      act = wire(:act, st != 0)
      inc_eff = wire(:inc_eff, mux(follow, inc_f, inc))
      sum = wire(:sum, zext(phase, 65) + zext(inc_eff, 65))
      carry = wire(:carry, sum[64])
      next_phase = wire(:next_phase, sum[0..63])
      top = fn p -> p[(64 - mclk_log2)..63] end

      phase_o <~ phase
      busy_o <~ act

      # alignment datapath
      r2 = wire(:r2, cat([rem, xs[17]]))
      ge1 = wire(:ge1, r2 >= @m)
      rem1 = wire(:rem1, trunc(mux(ge1, r2 - @m, r2), 62))
      d2 = wire(:d2, rem <<< 1)
      ge2 = wire(:ge2, d2 >= @m)
      rem2 = wire(:rem2, trunc(mux(ge2, d2 - @m, d2), 62))
      load = wire(:load, zext(pacc, 74) + zext(prod, 74))

      sync do
        # free running
        phase <~ next_phase
        rtp <~ add_wrap(rtp, zext(carry, 32))
        tick <~ carry
        mclk_en <~ (top.(next_phase) != top.(phase))

        # follow mode: inc from the wallclock increment
        fprod <~ (wc_inc * kscale)
        inc_f <~ trunc(fprod >>> 24, 64)
        if inc_wr, do: inc <~ inc_in

        aligned <~ 0

        if act, do: elapsed <~ add_wrap(elapsed, 1)

        switch st do
          0 ->
            if align do
              a_sec <~ now_sec[0..31]
              a_t <~ cat([now_ns[0..29], now_frac])
              elapsed <~ 1
              st <~ 1
            end

          1 ->
            x <~ (a_t * rate)
            sr <~ trunc(a_sec * rate + offset, 32)
            st <~ 2

          2 ->
            rem <~ x[18..79]
            xs <~ x[0..17]
            cnt <~ 0
            st <~ 3

          3 ->
            rem <~ rem1
            xs <~ trunc(xs <<< 1, 18)
            qacc <~ cat([qacc[0..16], ge1])
            cnt <~ add_wrap(cnt, 1)

            if cnt == 17 do
              cnt <~ 0
              st <~ 4
            end

          4 ->
            rem <~ rem2
            pacc <~ cat([pacc[0..62], ge2])
            cnt <~ add_wrap(cnt, 1)
            if cnt == 63, do: st <~ 5

          5 ->
            prod <~ (zext(add_wrap(elapsed, 2), 9) * inc_eff)
            st <~ 6

          _ ->
            phase <~ load[0..63]
            rtp <~ trunc(sr + zext(qacc, 32) + zext(load[64..72], 32), 32)
            tick <~ 0
            mclk_en <~ 0
            aligned <~ 1
            st <~ 0
        end
      end
    end
  end
end
