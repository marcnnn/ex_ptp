defmodule ExPtp.RTL.Wallclock do
  @moduledoc """
  RTL wallclock, bit-exact with `ExPtp.Wallclock` (checked cycle by cycle in
  `test/rtl/wallclock_test.exs`): 48-bit seconds, 30-bit nanoseconds
  (zero-extended to 32 on the port) and a 32-bit sub-nanosecond fraction,
  advanced every `clk` cycle by the increment register (2^-32 ns per tick,
  `ExPtp.Wallclock.increment/2` computes it from a rate in ppb).

  Every command is a strobe with its operands on the same cycle and takes
  effect on that edge, so a multi-word update is atomic.

  | Strobe | Operands | Effect (model call) |
  |---|---|---|
  | `inc_wr` | `inc_in` (u40) | next ticks use the new increment |
  | `set_wr` | `set_sec`, `set_ns` | time := `Wallclock.new/1`, slew cleared, fraction 0 |
  | `step_wr` | `step_ns` (s30) | same tick adds `step_ns` ns: `tick/2` then `step_phase/2` |
  | `slew_wr` | `slew_q`, `slew_r`, `slew_ticks` | `Wallclock.slew/3` from the next tick; ignored while `slew_busy` |
  | `snap_wr` | | `snap_*` := the current time |
  | `cap` (bit i) | | `cap<i>_*` := the current time, `cap_valid` bit i set |
  | `cap_clr` (bit i) | | clears `cap_valid` bit i |

  Slew without a divider: the model spreads `total = delta_ns * 2^32` over
  `k` ticks as `floor(total / k)` per tick with the remainder carried. With
  `total = q*k + r` (`0 <= r < k`) that sequence is `q` per tick, and `q`
  grows by one (r := 0) whenever `r == k - 1` after a tick. Software does
  the one division (`slew_args/2`), the hardware only counts. A `slew_wr`
  during an active slew is ignored (`slew_busy`), unlike the model, which
  merges; wait for `slew_busy` to drop.

  Limits (the carry logic handles one second boundary per tick): `|delta|`
  of a slew at most 2^28 ns, `step_ns` within +-2^29 ns. Going below the
  epoch clamps to zero like the model.

  Outputs: `now_sec`, `now_ns`, `now_frac` (the registers; the value of
  cycle i is the model after i ticks), `snap_*`, `cap<i>_*`, `pps_tick` (one
  cycle after the second changed), `pps` (high while `ns < pps_width`),
  `slew_busy`.

  Options: `ncap:` capture inputs (2; 0 for none), `snap:` and `pps:` (true; false
  drops those ports, which also avoids unused instance outputs), `inc_out:` (false;
  adds the increment register as output `inc_out`), `nominal:` reset value of the
  increment (`8 * 2^32`, 125 MHz).

  The critical path is the 62-bit add of increment, slew share and step plus
  the second-carry select, one cycle.
  """
  use ExHdl.RTL
  import Bitwise

  @ns 1_000_000_000
  @m @ns <<< 32

  @doc "Operands `%{slew_q, slew_r, slew_ticks}` for a slew of `delta_ns` over `ticks` ticks."
  def slew_args(delta_ns, ticks) when ticks > 0 and abs(delta_ns) <= 1 <<< 28 do
    total = delta_ns <<< 32

    %{
      slew_q: Integer.floor_div(total, ticks),
      slew_r: Integer.mod(total, ticks),
      slew_ticks: ticks
    }
  end

  def build(opts \\ []) do
    ncap = Keyword.get(opts, :ncap, 2)
    snap? = Keyword.get(opts, :snap, true)
    pps? = Keyword.get(opts, :pps, true)
    inc_out? = Keyword.get(opts, :inc_out, false)
    nominal = Keyword.get(opts, :nominal, 8 <<< 32)

    tag =
      "c#{ncap}_s#{if snap?, do: 1, else: 0}_p#{if pps?, do: 1, else: 0}_i#{if inc_out?, do: 1, else: 0}_n#{nominal}"

    module "ptp_wallclock_#{tag}" do
      inc_wr = input(:inc_wr, 1)
      inc_in = input(:inc_in, 40)
      set_wr = input(:set_wr, 1)
      set_sec = input(:set_sec, 48)
      set_ns = input(:set_ns, 30)
      step_wr = input(:step_wr, 1)
      step_ns = input(:step_ns, s(30))
      slew_wr = input(:slew_wr, 1)
      slew_q = input(:slew_q, s(64))
      slew_r = input(:slew_r, 32)
      slew_ticks = input(:slew_ticks, 32)

      now_sec = output(:now_sec, 48)
      now_ns = output(:now_ns, 32)
      now_frac = output(:now_frac, 32)
      slew_busy = output(:slew_busy, 1)

      sec = reg(:sec, 48)
      acc = reg(:acc, 62)
      inc = reg(:inc, 40, reset: nominal)
      sl_q = reg(:sl_q, s(64))
      sl_r = reg(:sl_r, 32)
      sl_k = reg(:sl_k, 32)

      ns = acc[32..61]
      frac = acc[0..31]
      busy = wire(:busy, sl_k != 0)
      share = wire(:share, mux(busy, sl_q, 0))
      step = wire(:step, mux(step_wr, step_ns, 0) <<< 32)
      total = wire(:total, to_signed(acc) + to_signed(inc) + share + step)
      over = wire(:over, total >= @m)
      under = wire(:under, total < 0)
      empty = wire(:empty, sec == 0)
      wrapped = wire(:wrapped, trunc(as_unsigned(mux(over, total - @m, total + @m)), 62))
      plain = wire(:plain, trunc(as_unsigned(total), 62))

      now_sec <~ sec
      now_ns <~ zext(ns, 32)
      now_frac <~ frac
      slew_busy <~ busy
      if inc_out?, do: output(:inc_out, 40) <~ inc

      sync do
        if under and empty do
          acc <~ 0
        else
          acc <~ mux(over or under, wrapped, plain)
        end

        if over, do: sec <~ add_wrap(sec, 1)
        if under and not empty, do: sec <~ sub_wrap(sec, 1)

        if busy do
          k1 = sub_wrap(sl_k, 1)
          sl_k <~ k1
          if k1 == 0, do: sl_q <~ 0

          if k1 != 0 and sl_r == k1 do
            sl_q <~ add_wrap(sl_q, 1)
            sl_r <~ 0
          end
        end

        if inc_wr, do: inc <~ inc_in

        if slew_wr and not busy and slew_ticks != 0 do
          sl_q <~ slew_q
          sl_r <~ slew_r
          sl_k <~ slew_ticks
        end

        if set_wr do
          sec <~ set_sec
          acc <~ (set_ns <<< 32)
          sl_k <~ 0
          sl_q <~ 0
        end
      end

      if pps? do
        pps_width = input(:pps_width, 30)
        pps_tick = output(:pps_tick, 1, reset: 0)
        pps = output(:pps, 1)
        pps <~ (ns < pps_width)

        sync do
          pps_tick <~ over
        end
      end

      if snap? do
        snap_wr = input(:snap_wr, 1)
        snap_sec = output(:snap_sec, 48, reset: 0)
        snap_ns = output(:snap_ns, 32, reset: 0)
        snap_frac = output(:snap_frac, 32, reset: 0)

        sync do
          if snap_wr do
            snap_sec <~ sec
            snap_ns <~ zext(ns, 32)
            snap_frac <~ frac
          end
        end
      end

      if ncap > 0 do
        cap = input(:cap, ncap)
        cap_clr = input(:cap_clr, ncap)
        cap_valid = output(:cap_valid, ncap, reset: 0)

        sync do
          cap_valid <~ ((cap_valid ||| cap) &&& ~~~cap_clr)
        end

        for i <- 0..(ncap - 1) do
          cs = reg(:"cap#{i}_sec_r", 48)
          cn = reg(:"cap#{i}_ns_r", 32)
          cf = reg(:"cap#{i}_frac_r", 32)
          os = output(:"cap#{i}_sec", 48)
          on = output(:"cap#{i}_ns", 32)
          of = output(:"cap#{i}_frac", 32)
          os <~ cs
          on <~ cn
          of <~ cf

          sync do
            if cap[i] do
              cs <~ sec
              cn <~ zext(ns, 32)
              cf <~ frac
            end
          end
        end
      end
    end
  end
end
