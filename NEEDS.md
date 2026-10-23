# Needs from sibling libraries

## ex_hdl (../exhdl)

- RTL DSL (in progress): the wallclock (`ExPtp.Wallclock`: 80-bit seconds/ns/fraction
  counter with carry, programmable increment, phase step and exact slew) and the media
  clock NCO (`ExPtp.MediaClock.Nco`) are counters, not scan kernels, so they wait for it.
  Both models are written to be compared bit for bit with the RTL.
- Scan kernels with a wider error input: `ExPtp.Servo.pi_step/5` needs a 32-bit error,
  28-bit state, 24-bit gains; the widest product fits s64 only because the width check
  rejects 40-bit inputs. If 40+ bit errors are wanted (offsets beyond 8 ms), the width
  check would need `:param_ranges`-style input bounds to be usable with `run_scan`.
- `ExHdl.DSP.analyze_scan/3` needs `ii: 2` for the servo (multiply in the feedback loop).
  Fine for one sample per sync interval; nothing to change, noted for the RTL integration.

## ex_net (../ex_net)

Resolved by the integration wave (contracts in `ExNet.RTL.Ifc`, tests in `test/integration/`):

- Hardware timestamp interface: `rx_sof`, `tx_sof`, `tx_tag` of `MacRx` / `MacTx`, delivered with
  each frame; the TX tag is the `tuser` of the first beat. Done and tested behind the real MACs.
- One-step Sync: `TxInsert` in front of `MacTx` writes the timestamp, the MAC appends the FCS
  afterwards (checked by decoding with the MAC RX model), UDP checksum zeroed. Not done: the
  incremental checksum update for IPv6 or a nonzero IPv4 checksum.

Still open:

- UDP/IPv4 multicast 224.0.1.129 (ports 319/320) and L2 EtherType 0x88F7 (01:1B:19:00:00:00)
  filters for the classifier table in a NIC configuration, and the IGMP join for the PTP group
  (the classifier can match them; the test table uses `udp_dst_port: 319..320`).

## Wave 2: RTL (found while writing `lib/ex_ptp/rtl/`)

### ex_hdl (RTL DSL)

Minimal reproducers, all checked against the current tree. Each is a module that elaborates
and passes `ExHdl.RTL.Module` checks, then fails in Verilator `-Wall` (so `Cosim.build/2` and
`ExHdl.Sim.Verilator.build/3` return `{:error, _}`) or in Yosys.

1. Unused instance outputs and partly read instance outputs fail lint (`UNUSEDSIGNAL`).
   The backend adds pragmas for a module's own signals but not for the wires of instance ports.

   ```elixir
   child = module "c" do
     a = input(:a, 4); x = output(:x, 4); y = output(:y, 4); x <~ a; y <~ a
   end
   top = module "t" do
     a = input(:a, 4); q = output(:q, 2)
     u = instance(:u, child, connect: [a: a])
     q <~ u.x[0..1]          # u_y unused, u_x[3:2] unused
   end
   ```

   Workaround in ex_ptp: modules take options that drop optional outputs, benches export
   every output. Wished: `lint_off UNUSEDSIGNAL` around the instance port wires, or an
   explicit `ignore(u.y)`.

2. An instance named like a signal inside the child fails lint (`VARHIDDEN`): a parent with
   `instance(:off, child)` and a child with `wire(:off, ...)`. Names inside library modules
   (`sum`, `off`, `mag`) then collide with the instance names of whoever uses them. Wished:
   prefix instance wires and the instance label, or check at elaboration.

3. SystemVerilog keywords that `Builder.name!/1` accepts: `within`, `throughout`, `intersect`,
   `first_match`, `matches`, `tagged`, `solve`, `before`, `bins`, `binsof`, `cross`, `expect`,
   `ignore_bins`, `illegal_bins`, `wildcard`, `alias`, `ref`, `local`, `new`, `virtual`,
   `modport`, `covergroup`, `rand`, `randc`, `unique0`, `restrict`, `soft`, `checker`,
   `coverpoint`, `endchecker`, `forkjoin`, `nexttime`, `accept_on`, `reject_on`, `eventually`,
   `s_always`, `until`, `global`, `implies`, `sync_accept_on`, `untyped`, `weak`, `strong`
   (`wire(:within, a)` gives "syntax error, unexpected within" in Verilator).

4. Yosys rejects the SystemVerilog emitted for negation of a signed value:
   `q <~ as_unsigned(-a)` with `a` s32 becomes `$unsigned(33'(-33'(a)))` and
   `read_verilog -sv` stops with "Static cast with zero or negative size!" (Verilator accepts
   it). `0 - a` (`sub_wrap(const(0, s(33)), sext(a, 33))`) works.

5. Closed loop co-simulation: `Cosim.run/3` takes the whole stimulus up front, so a testbench
   that reacts to outputs (AXI4-Stream `tready`, a network model, a servo loop) cannot run in
   Verilator through it. ex_ptp's tests drive the BEAM simulator cycle by cycle and replay the
   recorded inputs in Verilator, and the 2-clock servo loop uses a hand written C++ harness
   through `ExHdl.Sim.Verilator.build(sources, top, harness: path)`. Wished: a session API
   (`Cosim.open/2`, `poke`, `peek`, `step` over a pipe) with the same event model as `Sim`.

6. `Wrap.scan/1` black boxes have no BEAM model, so `ptp_servo` (kernel inside) can only be
   run in Verilator. A model derived from the Nx kernel (`NxFixed.run_scan` stepped per
   sample with the kernel's latency and `ii`) would let `Sim` run it. The wrapped ports are
   unsigned vectors for signed kernels (`tdata`, `p_*`), which needs `as_unsigned/1` in the
   caller; typed ports would be nicer.

7. Verilator speed with `Cosim.build` flags: `ExHdl.Sim.Verilator.build/3` has no option for
   `-O3` or `--threads`; the two-clock servo loop needs about 1 s per 3 million cycles. Only a
   wish.

### ex_net (../ex_net)

What `ExPtp.RTL.TimestampUnit`, `RxStamp` and `TxInsert` expect is now `ExNet.RTL.Ifc` (strobes,
streams, `tuser` layouts, timing) and is met by `MacRx` / `MacTx` and verified with them:

- Resolved: `rx_sof` / `tx_sof` offsets and the compensation (`TimestampUnit.nominal_comp/3`, measured
  error -3.8..+2.6 ns); `tx_tag` from the `tuser` of the first TX beat; RX `tuser` is the MAC's 4 bit
  field (bit 0 = bad) instead of 1 bit; every `rx_sof` is followed by exactly one frame;
  `TxInsert` passes `tuser` on; the MAC takes the first beat then does not stall, and a source that
  pauses goes through a store-and-forward FIFO (`ExNet.RTL.TxPath`); the delay from the first beat
  accepted by `TxInsert` to the Start word is 2 cycles (`Ifc.tx_first_beat_cycles/0`).
- Open: the MAC option "adjust the UDP checksum at the end of the frame" for IPv6 and nonzero IPv4
  checksums (`TxInsert` zeroes the IPv4 UDP checksum).
- Open: `RxStamp` runs its own `PtpDetect`; the classifier's metadata (ethertype, UDP ports) could
  replace most of it (about 160 LUT).
- Open: the integration runs MAC and system on one clock. Between a 156.25 MHz MAC clock and a
  different system clock the frame stream needs an `ExHdlCores.FIFO.axis_async/1`; the strobe path
  (pulse synchroniser) is tested with unrelated clocks.

### ex_hdl_xilinx (../ex_hdl_xilinx)

- Constraints for the CDC cells the PTP RTL relies on: `ExHdl.RTL.CDC.pulse_sync` (ASYNC_REG
  chain, already marked) and the `cdc: true` register of `TimestampUnit` that samples the
  held `tag_hold` register: `set_max_delay -datapath_only <mac period>` from
  `tag_hold*` to `c_tag*`, and `set_false_path` or the same from the toggle register of the
  pulse synchronisers' source.

### ex_pcie (../ex_pcie)

- Atomic wallclock access: write the operands of a command (`slew_q`, `slew_r`,
  `slew_ticks`, `set_sec`, ...) then one strobe register; read `snap_*` after a `snap_wr`
  strobe. `ExPtp.RTL.Wallclock` has the strobes and shadow registers; the BAR map is the
  integrator's job.

## Interop findings

From running `ExPtp.Port` against linuxptp 4.2 `ptp4l` and Wireshark 4.4 in containers
(`mix test --only interop`, README "Interop").

### 1. Fixed: default `time_source` was 0xA, IEEE 1588 INTERNAL_OSCILLATOR is 0xA0

`lib/ex_ptp/data_sets.ex` (`TimePropertiesDS` default and its moduledoc) uses `0xA`. The
TimeSource enumeration (IEEE 1588-2019 table 6) is ATOMIC_CLOCK 0x10, GPS 0x20,
TERRESTRIAL_RADIO 0x30, PTP 0x40, NTP 0x50, HAND_SET 0x60, OTHER 0x90, INTERNAL_OSCILLATOR 0xA0.

Evidence: ptp4l's Announce carries `time_source: 160` (decoded with `ExPtp.Message`, captured with
tcpdump from a ptp4l master); the Announce of `ExPtp.Port` is shown by Wireshark as
`TimeSource: Unknown (0x0a)`.

```elixir
# mix run -r test/interop/support/interop.ex repro.exs   (needs the tshark image)
tp = %ExPtp.DataSets.TimeProperties{}
IO.inspect(tp.time_source)    # 10, should be 160
# tshark -V on an Announce with time_source 10 prints "TimeSource: Unknown (0x0a)",
# with 0xA0 it prints the INTERNAL_OSCILLATOR name
```

Fix: `time_source: 0xA0`. `foreign_masters.ex` and the tests use 0x20 (GPS), which is right.

### 2. Servo gains are the hardware timestamp ones; software timestamps flap the lock

`ExPtp.Servo.gains/1` follows linuxptp's hardware timestamp constants (kp 0.7, ki 0.3 scaled by the
sync interval). linuxptp's `pi.c` uses `SWTS_KP_SCALE 0.1` and `SWTS_KI_SCALE 0.001` when the timestamps are
software ones, and its servo waits `0.016 / ki` seconds (16 s) before it estimates the frequency.
`ExPtp.Port` has no option to change the gains (`ensure_servo/1`).

Evidence (`test/interop/ptp4l_test.exs`, profile `aes67`, test (a)): ptp4l as master with
`--logSyncInterval=-3`, `ExPtp.Port` slave on `PtpInterop.UdpTransport` (software timestamps). With
`lock_ns: 100_000` a manual run showed 13 UNCALIBRATED/SLAVE transitions in 40 s, clock error against
the shared kernel clock up to 380 us and one sample at -1.9 ms. The test uses `lock_ns: 500_000` and
still sees 8 UNCALIBRATED/SLAVE round trips in 40 s (median error 36 us). At 1 s sync (default
profile) the port goes SLAVE once and stays there, median error 46 us.

The default `lock_threshold_ns` of 500 cannot be reached with software timestamps (offsets are tens of
microseconds); the interop tests pass 100 us (default profile) and 500 us (AES67 profile).

Suggestion: a `:servo_gains` option or a `:timestamping` option (`:hardware` | `:software`) that picks
the gains, and a lock threshold that follows it.

### 3. The UDP transport with software timestamps belongs in lib

`test/interop/support/udp_transport.ex` (`PtpInterop.UdpTransport`) implements `ExPtp.Transport` over UDP/IPv4
multicast (224.0.1.129, ports 319/320) with the OTP `:socket` module: `SO_TIMESTAMP` (kernel receive
time, microsecond resolution), transmit timestamp read right before `sendto`, a software clock on top
of CLOCK_REALTIME with offset, rate (`adjust_frequency/2`) and step (`step_clock/2`), optional TAI
offset. It should move to `lib/` (the SDR use case will want it anyway). Known weaknesses: the transmit
timestamp is taken before the send (about 40 us early, visible as a constant offset in ptp4l's log),
`SO_TIMESTAMPING` with the error queue would fix that; `schedule/3` is millisecond granular (BEAM timers); no
IPv6, no L2 (0x88F7), no peer delay (224.0.0.107, TTL 1).

### 4. Timescale: the Announce promises TAI, the transport must deliver it

`TimePropertiesDS` defaults to `ptp_timescale: true`, `current_utc_offset: 37`,
`current_utc_offset_valid: false`. A transport on CLOCK_REALTIME (UTC) then sends timestamps 37 s behind
the timescale it announces. Evidence: ptp4l as slave logged `master offset 37000028982 s0` until the
transport added 37 s (`tai_offset_s: 37` in `PtpInterop.UdpTransport`). ptp4l with `-S` as master announces an
arbitrary timescale (no `ptp_timescale` flag) and sends REALTIME. `ExPtp.Transport.now/1` should say which
timescale it returns, and `current_utc_offset_valid` should probably follow the transport.

### 5. What matched

- ptp4l (4.2, `-S -E -4`, domain 0) accepted Announce, Sync, Follow_Up and Delay_Resp of `ExPtp.Port`: it went
  LISTENING, UNCALIBRATED (RS_SLAVE), SLAVE (MASTER_CLOCK_SELECTED) with servo states s0, s1, s2, mean path delay 60 to 75 us, offsets
  of tens of microseconds (the early transmit timestamp). Default and AES67 intervals.
- `ExPtp.Port` as slave synchronised to ptp4l masters with both sets of intervals; mean path delay and
  offset sane. ptp4l's header minorVersionPTP 1 is accepted.
- BMCA: priority1 (ptp4l lower and port lower), a priority1 change at run time through `pmc`, and the
  clockIdentity tie break with equal priorities (port identity just below or above ptp4l's) pick the
  expected master on both sides.
- Every frame of a ptp4l / `ExPtp.Port` exchange decodes with `ExPtp.Message` and agrees with Wireshark's
  fields; the Wireshark samples `ptpv2.pcap` and `ptpv2_anon.pcapng` (Sync, Pdelay_Req, Announce) too.
- ptp4l in an unprivileged container cannot adjust CLOCK_REALTIME, and a failed adjustment resets its
  servo (it never leaves s0). `containers/linuxptp/fakeclock.c` (LD_PRELOAD) makes `clock_adjtime` and
  `clock_settime` succeed without touching the clock.

### 6. Not covered

Peer delay (P2P) against ptp4l (`ExPtp.Port` has P2P since wave 3, tested in `ExPtp.Sim` only), transparent clocks, L2 transport against ptp4l (`-2`, not tried), one-step Sync, hardware timestamping, the AES67
profile's announce timeout and domain constraints on a switch, other implementations (a PTP
grandmaster, Dante, AVB `gptp`).


## Wave 3 leftovers (ex_ptp internal)

- `test/ex_ptp/sim_test.exs` "SMPTE ST 2059-2 profile ..." passes in the full run but fails when run
  alone (`mix test test/ex_ptp/sim_test.exs:<line>`): neither port sends anything in 15 s. Looks like a
  start-up race between `Port`'s `handle_continue` and the first `Sim.run_for`; not investigated.
- The delay paths are closed loop in `ExPtp.Sim` (BEAM, drift, jitter); not yet through the Cosim session
  API (`ExHdl.RTL.Cosim` open/poke/peek/step) against the RTL servo/timestamp unit.
- Profile numbers still unverified against AES67 / ST 2059-2 text (see `ExPtp.Profile` moduledoc).
- Interop items 2-4 (software timestamp gains, UDP transport in lib, timescale) still open.
