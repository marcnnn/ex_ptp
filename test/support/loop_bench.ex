defmodule ExPtp.Test.LoopBench do
  @moduledoc false
  # Closed loop in RTL: a master and a slave wallclock on two unrelated clocks, the slave with the
  # offset calculation, the servo (wrapped scan kernel) and the rate adjust of its wallclock.
  # A C++ harness plays network and software: it asserts timestamp captures at the clock edge after a
  # message "arrives" (delays and jitter in true time), hands t1 and t4 over like message payloads and
  # triggers the offset calculation.
  use ExHdl.RTL
  import Bitwise

  alias ExPtp.RTL.{Offset, Servo, Wallclock}

  def build(tick_ns) do
    nominal = tick_ns <<< 32

    module "ptp_loop_t#{tick_ns}" do
      domain(:m, clock: :clk_m, reset: :rst_m_n)
      domain(:s, clock: :clk_s, reset: :rst_s_n)

      m_set_wr = input(:m_set_wr, 1, domain: :m)
      m_set_sec = input(:m_set_sec, 48, domain: :m)
      m_set_ns = input(:m_set_ns, 30, domain: :m)
      m_cap = input(:m_cap, 2, domain: :m)
      s_set_wr = input(:s_set_wr, 1, domain: :s)
      s_set_sec = input(:s_set_sec, 48, domain: :s)
      s_set_ns = input(:s_set_ns, 30, domain: :s)
      s_cap = input(:s_cap, 2, domain: :s)
      t1 = for {n, w} <- [sec: 48, ns: 30, frac: 16], do: input(:"t1_#{n}", w, domain: :s)
      t4 = for {n, w} <- [sec: 48, ns: 30, frac: 16], do: input(:"t4_#{n}", w, domain: :s)
      calc = input(:calc, 1, domain: :s)
      load = input(:load, 1, domain: :s)
      kp = input(:kp, s(24), domain: :s)
      ki = input(:ki, s(24), domain: :s)
      thr = input(:thr, 32, domain: :s)
      thr_unlock = input(:thr_unlock, 32, domain: :s)
      needed = input(:needed, 8, domain: :s)
      step_thr = input(:step_thr, 32, domain: :s)

      mwc =
        instance(:mwc, Wallclock.build(ncap: 2, snap: false, pps: false, nominal: nominal),
          domains: [sys: :m]
        )

      swc =
        instance(:swc, Wallclock.build(ncap: 2, snap: false, pps: false, nominal: nominal),
          domains: [sys: :s]
        )

      off = instance(:off, Offset.build(), domains: [sys: :s])
      sv = instance(:sv, Servo.build(), domains: [sys: :s])

      # master: only captures and a settable clock
      mwc.set_wr <~ m_set_wr
      mwc.set_sec <~ m_set_sec
      mwc.set_ns <~ m_set_ns
      mwc.cap <~ m_cap
      mwc.cap_clr <~ const(0, u(2))
      for p <- ~w(inc_wr step_wr slew_wr)a, do: mwc[p] <~ 0
      for {p, w} <- [inc_in: 40, slew_r: 32, slew_ticks: 32], do: mwc[p] <~ const(0, u(w))
      mwc.step_ns <~ const(0, s(30))
      mwc.slew_q <~ const(0, s(64))

      # slave: set, captures, servo rate adjust and the step when the offset is large
      pack = fn w, i ->
        cat([w[:"cap#{i}_sec"], w[:"cap#{i}_ns"][0..29], w[:"cap#{i}_frac"][16..31]])
      end

      swc.set_wr <~ s_set_wr
      swc.set_sec <~ s_set_sec
      swc.set_ns <~ s_set_ns
      swc.cap <~ s_cap
      swc.cap_clr <~ const(0, u(2))
      swc.inc_wr <~ sv.inc_wr
      swc.inc_in <~ sv.inc
      swc.slew_wr <~ 0
      for {p, w} <- [slew_r: 32, slew_ticks: 32], do: swc[p] <~ const(0, u(w))
      swc.slew_q <~ const(0, s(64))

      off.go <~ calc
      off.t1 <~ cat(t1)
      off.t2 <~ pack.(swc, 0)
      off.t3 <~ pack.(swc, 1)
      off.t4 <~ cat(t4)

      err = off.err
      mag = wire(:mag, mux(err < 0, as_unsigned(-err), zext(as_unsigned(err[0..30]), 33)))
      big = wire(:big, mag > step_thr)
      swc.step_wr <~ (off.valid and big)
      swc.step_ns <~ trunc(-((err + 128) >>> 8), 30)

      sv.err_valid <~ (off.valid and not big)
      sv.err <~ err
      sv.load <~ load
      sv.pre_wr <~ 0
      sv.pre <~ const(0, s(28))
      sv.kp <~ kp
      sv.ki <~ ki
      sv.nominal <~ const(nominal, u(40))
      sv.scale <~ const(Servo.scale(nominal), u(48))
      sv.thr <~ thr
      sv.thr_unlock <~ thr_unlock
      sv.needed <~ needed

      outs = [
        m_now_sec: mwc.now_sec,
        m_now_ns: mwc.now_ns,
        m_now_frac: mwc.now_frac,
        s_now_sec: swc.now_sec,
        s_now_ns: swc.now_ns,
        s_now_frac: swc.now_frac,
        m_cap0_sec: mwc.cap0_sec,
        m_cap0_ns: mwc.cap0_ns,
        m_cap0_frac: mwc.cap0_frac,
        m_cap1_sec: mwc.cap1_sec,
        m_cap1_ns: mwc.cap1_ns,
        m_cap1_frac: mwc.cap1_frac,
        s_cap0_sec: swc.cap0_sec,
        s_cap0_ns: swc.cap0_ns,
        s_cap0_frac: swc.cap0_frac,
        s_cap1_sec: swc.cap1_sec,
        s_cap1_ns: swc.cap1_ns,
        s_cap1_frac: swc.cap1_frac,
        m_cap_valid: mwc.cap_valid,
        m_slew_busy: mwc.slew_busy,
        s_cap_valid: swc.cap_valid,
        s_slew_busy: swc.slew_busy,
        off_valid: off.valid,
        off_err: off.err,
        off_mpd: off.mpd,
        stepped: off.valid and big,
        ppb_valid: sv.ppb_valid,
        ppb: sv.ppb,
        locked: sv.locked,
        dropped: sv.dropped,
        range_err: sv.range_err,
        inc: sv.inc,
        inc_wr: sv.inc_wr
      ]

      for {name, e} <- outs do
        o = output(:"x_#{name}", ExHdl.RTL.Expr.type!(e.type))
        o <~ e
      end
    end
  end

  @doc "Unused-bit sinks: Verilator -Wall wants every instance output bit read; the bench reads them all."
  def harness do
    File.read!(Path.join(__DIR__, "loop_harness.cpp"))
  end

  def harness_path, do: Path.join(__DIR__, "loop_harness.cpp")

  @doc "Builds (cached) the closed loop simulation and returns the executable."
  def executable(tick_ns) do
    mod = build(tick_ns)
    sources = ExHdl.Backends.SystemVerilog.RTL.generate(mod)

    case ExHdl.Sim.Verilator.build(sources, mod.name, harness: harness_path()) do
      {:ok, exe} -> exe
      {:error, e} -> raise "closed loop build failed: #{e}"
    end
  end

  @doc """
  Runs the loop. Options: `:intervals`, `:interval_ns`, `:seed`, `:delay_ns`, `:jitter_ns`,
  `:master_ppb`, `:slave_ppb` (clock frequency errors), `:tick_ns`, `:init_offset_ns`, `:gains`
  (`{kp_raw, ki_raw}`), `:thr_ns`, `:unlock`, `:needed`, `:step_ns`, `:turn_ns`.
  Returns `%{trace: [{k, true_offset_ns, ppb_raw, locked}], errs: [{t_ns, true_offset, err_raw}], done: [...]}`.
  """
  def run(opts) do
    o = Keyword.merge(defaults(), opts)
    exe = executable(o[:tick_ns])
    {kp, ki} = o[:gains]

    args =
      [
        o[:intervals],
        o[:interval_ns],
        o[:seed],
        o[:delay_ns],
        o[:jitter_ns],
        o[:master_ppb],
        o[:slave_ppb],
        o[:tick_ns],
        o[:init_offset_ns],
        kp,
        ki,
        o[:thr_ns] * 256,
        o[:thr_ns] * o[:unlock] * 256,
        o[:needed],
        o[:step_ns] * 256,
        o[:turn_ns]
      ]
      |> Enum.map(&to_string/1)

    {out, 0} = System.cmd(exe, args, stderr_to_stdout: true)

    lines = String.split(out, "\n", trim: true) |> Enum.map(&String.split(&1, " "))

    %{
      trace:
        for(
          ["S", k, off, ppb, l] <- lines,
          do: {String.to_integer(k), String.to_float(off), String.to_integer(ppb), l == "1"}
        ),
      errs:
        for(
          ["E", t, off, e] <- lines,
          do: {String.to_integer(t), String.to_float(off), String.to_integer(e)}
        ),
      done: for(["D" | rest] <- lines, do: Enum.map(rest, &String.to_integer/1)) |> List.first()
    }
  end

  defp defaults do
    {kp, ki} = ExPtp.Servo.gains(-3)
    f = ExPtp.Servo.FixedPI.new(kp, ki)

    [
      intervals: 40,
      interval_ns: 125_000_000,
      seed: 7,
      delay_ns: 5_000,
      jitter_ns: 200,
      master_ppb: -20_000,
      slave_ppb: 50_000,
      tick_ns: 80,
      init_offset_ns: 3_000_000,
      gains: {f.kp, f.ki},
      thr_ns: 500,
      unlock: 2,
      needed: 5,
      step_ns: 100_000,
      turn_ns: 1_000_000
    ]
  end
end
