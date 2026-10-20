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

- Hardware timestamp interface for the future real `ExPtp.Transport`: ingress timestamp
  (wallclock at SFD) delivered with each received frame/payload, and an egress timestamp
  returned or reported for frames sent through the event path (per-frame tag to match).
- One-step Sync support in the MAC: insert the origin timestamp and update the checksum/FCS
  for UDP (UDP checksum zero or incremental update) and L2.
- UDP/IPv4 multicast 224.0.1.129 (ports 319/320) and L2 EtherType 0x88F7 (01:1B:19:00:00:00)
  filters, and IGMP join for the PTP group.

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

What `ExPtp.RTL.TimestampUnit`, `RxStamp` and `TxInsert` expect (also in their moduledocs):

- `rx_sof` and `tx_sof`: one-cycle strobes in the MAC clock domain at the start-of-frame
  delimiter on the wire side; `tx_tag` (8 bits) valid in the `tx_sof` cycle, taken from the
  `tuser` of the first TX beat. At least 8 MAC cycles between two SOFs of one kind.
- Every `rx_sof` is followed by exactly one frame on the RX AXI4-Stream (bad frames
  included, flagged by `tuser = 1` on the last beat), in order, none dropped after the SOF.
  Little endian lanes (byte 0 in `tdata[7:0]`), `tkeep` contiguous from lane 0.
- TX: the MAC takes the first beat without arbitrary delay and then does not stall; the delay
  from the first accepted beat to the first bit on the wire is constant (calibrated into
  `comp`). The FCS is appended after the stream passes `TxInsert` (so it covers the written
  timestamp), the frame must not carry one. For one-step the TX stream and the wallclock
  share one clock; for a wallclock on another clock a time replica is needed.
- Optional MAC option "adjust the UDP checksum at the end of the frame" for IPv6 and for
  nonzero IPv4 checksums; without it `TxInsert` zeroes the IPv4 UDP checksum.

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
