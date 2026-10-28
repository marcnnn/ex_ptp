# ExPtp

IEEE 1588-2019 with the time-critical part in hardware and the protocol
logic on the BEAM.

## Status

The BEAM side, the bit-exact reference models and the hardware RTL
(`ExHdl.RTL`: wallclock, timestamp unit, PTP detection, one-step insertion,
servo, offset calculation, media clock NCO) are done. The RTL is verified
cycle by cycle against the models in the BEAM simulator and Verilator, and as
a closed loop with two clocks (see "Hardware").

| Part | Module | Status |
|---|---|---|
| Message codecs (header, Sync, Delay_Req, Follow_Up, Delay_Resp, Announce, Pdelay_*, Signaling, Management header + TLVs) | `ExPtp.Message`, `ExPtp.TLV`, `ExPtp.Timestamp`, `ExPtp.Correction` | done, property tested |
| Data sets, BMCA (comparison incl. topology, state decision), foreign master qualification | `ExPtp.DataSets`, `ExPtp.BMCA`, `ExPtp.ForeignMasters` | done |
| Port state machine, profiles (default, AES67, SMPTE ST 2059-2) | `ExPtp.PortState`, `ExPtp.Profile` | done |
| Ordinary clock process over a pluggable transport (E2E delay mechanism) | `ExPtp.Port`, `ExPtp.Transport` | done |
| Simulated network: delay, asymmetry, jitter, loss, drift | `ExPtp.Sim`, `ExPtp.Sim.Node` | done |
| Offset and mean path delay, E2E and P2P | `ExPtp.Delay` | done (model) |
| Wallclock | `ExPtp.Wallclock`, `ExPtp.RTL.Wallclock` | done (model, RTL bit-exact) |
| PI servo, lock detection | `ExPtp.Servo` (`pi_step`, `lock_step` scan kernels), `ExPtp.Servo.FixedPI`, `.PI`, `.Lock`, `ExPtp.RTL.Servo`, `ExPtp.RTL.Offset` | done (model, RTL) |
| Media clock: RTP timestamp, NCO | `ExPtp.MediaClock`, `ExPtp.RTL.MediaNco` | done (model, RTL) |
| Timestamp unit, PTP detection, one-step Sync insertion | `ExPtp.RTL.TimestampUnit`, `.PtpDetect`, `.RxStamp`, `.TxInsert` | done (RTL), tested behind the ex_net MAC (`test/integration/`) |
| Peer delay mechanism in the port, management messages, one-way/multi-port clocks | | not done |
| Validation against ptp4l | | not done |
| Real transport (MAC timestamps over ex_net, PCIe wallclock access) | | the timestamp path is tested through the MAC; the `ExPtp.Transport` glue and PCIe access are not written |

ex_net is a (path) dependency for the shared interfaces (`ExNet.RTL.Ifc`: MAC receive and
transmit streams, `rx_sof` / `tx_sof` / `tx_tag`); the BEAM side still treats PTP
messages as plain payloads (UDP ports 319 and 320, or L2 with EtherType 0x88F7), framing
is the transport's job.

## API overview

```elixir
# codec
msg = ExPtp.Message.new(:sync, {clock_id, 1}, 7, %{origin_timestamp: ExPtp.Timestamp.new(5, 6)})
bin = ExPtp.Message.encode(msg)
{:ok, ^msg} = ExPtp.Message.decode(bin)      # {:error, reason} on malformed input, never raises

# BMCA
d0 = ExPtp.DataSets.Default.new(clock_id, profile: :aes67) |> ExPtp.BMCA.from_default(1)
ExPtp.BMCA.compare(a, b)                      # {:a | :b, :dataset | :topology} | :equal
ExPtp.BMCA.state_decision(d0, erbest, :listening, false)   # :m1 | :m2 | :s1 | :p1 | :p2 | :listening

# two clocks in virtual time
sim = ExPtp.Sim.start(seed: 1, delay_ns: 5_000, jitter_ns: 200)
m = ExPtp.Sim.add_node(sim, :m, drift_ppm: -20)
s = ExPtp.Sim.add_node(sim, :s, drift_ppm: 50, initial_offset_ns: 3_000_000)
{:ok, _} = ExPtp.Port.start_link(transport: m, clock_identity: <<1::64>>, profile: :aes67, clock_class: 6)
{:ok, slave} = ExPtp.Port.start_link(transport: s, clock_identity: <<2::64>>, profile: :aes67)
ExPtp.Sim.run_for(sim, 60_000_000_000)
ExPtp.Port.info(slave)                        # state: :slave, offset_ns, mean_path_delay_ns, locked, ...
```

Reference models, all integer and deterministic unless noted:

| Model | Shape |
|---|---|
| `ExPtp.Wallclock` | `tick(w, inc) -> w`, `step(w, inc) -> {time, w}`, `advance(w, inc, n)`, `step_phase/2`, `slew/3`; `inc` in 2^-32 ns per tick, `increment(nominal, ppb)` |
| `ExPtp.Delay` | `e2e_mean_path_delay/6`, `p2p_mean_path_delay/6`, `offset_from_master/4`, `rate_ratio/4`; scaled ns (2^-16) |
| `ExPtp.Servo.pi_step/5` | `step(err, integ, kp, ki, format: f) -> {ppb, integ}`, float (`Num.float()`) or fixed (`Servo.fixed_format()`); `Servo.run/4` on the CPU reference, `ExHdl.DSP.analyze_scan/3` with `ii: 2` for hardware |
| `ExPtp.Servo.FixedPI` | the same recurrence on raw integers, bit-identical to the kernel |
| `ExPtp.Servo.lock_step/4` | `step(err, run, thr, needed) -> {locked, run}` |
| `ExPtp.MediaClock` | `rtp_timestamp(ptp_time, rate, offset)`, `sample_time/4`; `Nco.step(phase, inc) -> {tick, phase}` |

Custom transports implement `ExPtp.Transport` (send with hardware egress
timestamp, local clock read, timers, frequency adjust, phase step).

## Hardware

All modules are `ExHdl.RTL` generators in `lib/ex_ptp/rtl/` (`Module.build/1`
returns the module; `ExHdl.Backends.SystemVerilog.RTL.generate/1` the SV).
Tests (`test/rtl/`) compare the BEAM simulator with the models, then Verilator
with the BEAM simulator on StreamData stimulus (tag `:verilator`); resource
numbers need Yosys (tag `:yosys`). Streams are AXI4-Stream with little endian
lanes (byte 0 in `tdata[7:0]`).

| Module | What | Ports (besides clock and `rst_n`) |
|---|---|---|
| `RTL.Wallclock` | 48-bit s, 30-bit ns, 32-bit fraction; `ExPtp.Wallclock` bit for bit | strobes `inc_wr`, `set_wr`, `step_wr`, `slew_wr`, `snap_wr`, `cap`, `cap_clr` with operands; outputs `now_*`, `snap_*`, `cap<i>_*`, `pps`, `pps_tick`, `slew_busy` |
| `RTL.TimestampUnit` | SOF to wallclock capture, MAC clock to system clock, compensation, TX tag FIFO | MAC domain `rx_sof`, `tx_sof`, `tx_tag` (`ExNet.RTL.Ifc.ts_rx/0`, `ts_tx/1`); `now_*`, `rx_comp`, `tx_comp`; `rx_valid`, `rx_ts`, `tx_ts_valid`, `tx_ts_tag`, `tx_ts`, `tx_pop`; `nominal_comp/3` |
| `RTL.PtpDetect` | EtherType 0x88F7 or UDP 319/320 after 0-2 VLAN tags, passive tap | `valid`, `data`, `keep`, `last`; `ptp`, `udp`, `mtype`, `ptp_off`, `ev_port`, `l4_off` |
| `RTL.RxStamp` | RX frames with timestamp and classification in `tuser` (102 bits, `RTL.Meta`) | `s_axis` (`ExNet.RTL.Ifc.mac_rx` with `tready`, bit 0 of the 4 bit user = bad), `m_axis` (user 102), `ts_valid`, `ts` |
| `RTL.TxInsert` | one-step Sync: origin timestamp written in the stream, UDP checksum zeroed | `s_axis`, `m_axis` (`ExNet.RTL.Ifc.mac_tx`, tag in `tuser` passed through), `enable`, `zero_csum`, `comp`, `now_*`, `stamped` |
| `RTL.Offset` | `Delay` offset and mean path delay from t1..t4 | `go`, `t1..t4` (94 bit), `valid`, `err`, `mpd` |
| `RTL.Servo` | `pi_step` kernel (wrapped), lock detector, ppb to increment | `err_valid`, `err`, `load`, `kp`, `ki`, `nominal`, `scale`, `thr*`, `needed`; `inc_wr`, `inc`, `ppb`, `locked` |
| `RTL.Ifc` | the media clock contract (`tick`, `rtp_ts`), pointers to `Meta` and the MAC strobes | `media_clock(:master \| :slave)` |
| `RTL.MediaNco` | sample tick, RTP timestamp, MCLK enable, alignment to PTP time | `now_*`, `rate`, `offset`, `inc_wr`/`inc_in` or `follow` + `wc_inc` + `kscale`, `align`; `tick`, `rtp_ts`, `mclk_en`, `aligned` (`RTL.Ifc.media_clock/2`) |

Moduledocs have the details; the points that matter for integration:

**Wallclock.** Commands are strobes with operands on the same cycle, so a
multi-word update is atomic. Increment 2^-32 ns per tick
(`Wallclock.increment/2`). `step_ns` is a signed 30-bit phase step; slew is
`slew_args/2` (software does the one division, the hardware counts), both
limited to a fraction of a second (the carry logic handles one second per
tick). The value of cycle i is the model after i ticks. One cycle critical
path: increment + slew share + step added to a 62-bit value, second carry.

**Timestamp path.** The wallclock runs on the system clock; `rx_sof` and
`tx_sof` (one-cycle strobes of `ExNet.RTL.MacRx` / `MacTx`, defined in `ExNet.RTL.Ifc`) cross
with a toggle pulse synchroniser, the tag as a held register sampled after the
pulse (a `cdc: true` register; needs a max-delay constraint). Capture happens
2 to 3 system periods after the SOF (measured 16 to 23 ns at 8 ns), jittering
by one system period, because the clocks are asynchronous: `rx_comp`/`tx_comp`
(2^-16 ns) subtract the mean latency; `TimestampUnit.nominal_comp(side, mac_period_ns,
sys_period_ns)` is that latency (2.5 system periods) plus the MAC's strobe offset (RX: the
`rx_sof` trails the Start word by 1 MAC cycle, TX: 0), which makes a stamp the wallclock at
the edge that samples the Start word on the wire. Measured behind the real MACs on
unrelated clocks (8 ns system, 6.4 ns MAC): error -3.8 to +2.6 ns for RX and TX
(`test/integration/mac_timestamp_test.exs`). With one clock the capture is exactly 3 cycles
after the strobe's cycle. With the wallclock on the MAC clock no crossing is needed. `RxStamp` queues the timestamps and waits for the first beat's
one; frames out of order or a lost SOF are handled (late timestamps are
discarded after `wait` cycles), the contract with the MAC is in the moduledoc.

**One-step.** `TxInsert` samples the wallclock when the first beat of a frame
is accepted, adds `comp` (delay to the wire), writes sec/ns over the 10-byte
origin field of Sync messages (L2 or UDP, 0-2 tags), and with `zero_csum`
zeroes the IPv4 UDP checksum of event-port frames. Streaming cannot produce a
correct nonzero checksum (it precedes the changed bytes and depends on their
old value); the FCS is appended by the MAC after this module, so it is correct
by construction. The stream and the wallclock must share a clock (wallclock on
the MAC TX clock).

**Servo.** The PI step is the Nx kernel `ExPtp.Servo.pi_step/5` generated by
`ExHdl.DSP.scan_to_sv/3` (`ii: 2`, latency 11) and wrapped with
`ExHdl.RTL.Wrap.scan/1`, so CPU reference, `FixedPI` and hardware share one
definition. A hand written RTL PI would duplicate the arithmetic; the price is
that wrapped kernels have no BEAM model, so the servo is checked in Verilator
against `FixedPI`, `Lock` and `Servo.inc_for/2` directly. `inc_wr`/`inc` plug
into the wallclock's `inc_wr`/`inc_in` (`inc = nominal + ppb * scale`, within
one unit of `Wallclock.increment/2`).

**Media clock.** `MediaNco` is `MediaClock.Nco` (a 64-bit phase accumulator;
tick on carry, RTP counter, `mclk_en` when the top 8 phase bits change: 256 per
sample, phase locked). `align` latches the wallclock and computes
`floor(t * rate) + offset` and the phase fraction with a 82-cycle sequential
divider, then loads the accumulator advanced by the elapsed cycles, so `rtp_ts`
and `phase` agree with the wallclock of the same cycle from `aligned` on
(tested at 48, 44.1, 96 and 8 kHz against exact integer arithmetic). In
`follow` mode the increment is derived from the wallclock's increment, so the
servo's rate corrections move the media clock too; `align` again after a
wallclock step.

### Verification, in numbers

| Test | Result |
|---|---|
| Wallclock vs `ExPtp.Wallclock` (random inc/set/step/slew/snap/cap, carries, epoch clamp) | identical every cycle (BEAM and Verilator) |
| Timestamp unit, two unrelated clocks | RX stamps equal compensated wallclock at the capture edge; latency 16 to 23 ns at 8 ns; TX tags in order, no loss |
| PtpDetect, RxStamp, TxInsert, 8/32/64-bit buses, random `tvalid`/`tready` | all frames classified like `PtpDetect.classify/1` (itself checked against the generator's truth), bytes unchanged except the written fields |
| Servo vs `FixedPI`/`Lock`/`inc_for` | identical PI output, increment and lock state per sample (Verilator) |
| `Offset` vs `Delay` and `FixedPI.err_from_scaled` | identical |
| `MediaNco` | equal to `Nco.step` per cycle; aligned within 1e-12 sample of exact |
| MAC TX (`ExNet.RTL.MacTx`) with `TimestampUnit`, two unrelated clocks | tag of every frame in order, stamp = wallclock at the Start word edge within -3.8..+2.6 ns |
| MAC RX (`ExNet.RTL.MacRx`) with `TimestampUnit`, two unrelated clocks | stamp of every frame = wallclock at the Start word edge within -3.8..+2.6 ns |
| `TxInsert` with `MacTx`, one clock | Sync origin timestamp = wallclock (whole ns) at the Start word edge, UDP checksum 0 on event ports, FCS valid (decoded by the MAC RX model), other frames unchanged |
| ex_aes67 `test/integration/` | RX frames (random VLAN, bad FCS, other traffic) and TX frames through the full chains: exact timestamps, one-step equals two-step |

**Closed loop** (`test/rtl/closed_loop_test.exs`, Verilator, about 30 s): a
master and a slave wallclock on unrelated clocks (4.17 MHz nominal, to keep the
simulation short; master 20 ppm slow, slave 50 ppm fast, 3 ms initial
offset); a C++ harness plays the network (5 us delay, 200 ns jitter, captures
asserted at the next clock edge after a message arrives, t1 and t4 handed over
like message payloads); offset calculation, servo and the wallclock rate
adjust are RTL, the first large offset is stepped. Results over 70 sync
intervals of 125 ms:

| | RTL | `Port` based BEAM simulation, same network |
|---|---|---|
| peak offset after the step | 33.8 us | 40.2 us |
| intervals until the offset stays within 3 us | 27 | 64 |
| largest offset in the last 10 intervals | 169 ns (still decaying) | 56 to 82 ns (after 480 intervals) |
| servo frequency | -70125 ppb | about -70000 ppb |
| locked after | 60 intervals | |

The RTL follows the bare `FixedPI` recurrence with a plain plant to within 74
ns over the whole run. The `Port` run is slower because it sends Delay_Req
once a second with a filtered path delay and restarts its servo after the step
(not analysed further).

### Resources

Yosys `synth_xilinx -family xcup` (UltraScale+), numbers of the block alone
(`mix test --only yosys` prints them):

| Module | LUT | FF | DSP | LUTRAM |
|---|---|---|---|---|
| Wallclock, 2 captures + snapshot + PPS | 555 | 611 | 0 | 0 |
| Wallclock, bare | 535 | 278 | 0 | 0 |
| TimestampUnit | 288 | 217 | 0 | 8 |
| PtpDetect 64 bit | 161 | 169 | 0 | 0 |
| PtpDetect 8 bit | 172 | 166 | 0 | 0 |
| RxStamp 64 bit | 159 | 362 | 0 | 7 |
| TxInsert 64 bit | 525 | 418 | 0 | 0 |
| TxInsert 8 bit | 318 | 352 | 0 | 0 |
| Servo (PI kernel, lock, rate) | 816 | 545 | 14 | 3 |
| Offset | 347 | 182 | 2 | 0 |
| MediaNco | 1074 | 749 | 24 | 0 |

No block RAM anywhere. Synthesis only, no timing; the wallclock add is the
path to watch above 250 MHz.

### Not done

No hardware peer delay, no IPv6 detection, no timestamp replica for one-step
on another clock domain, no PCIe register map (see `NEEDS.md`). The detector
looks at IPv4 with IHL 5 only.

## The hardware library set

ExHdl itself only provides the basics (RTL DSL, simulation, SystemVerilog,
targets, tool drivers). Function lives in these siblings:

| Library | Scope |
|---|---|
| [ex_hdl_cores](https://github.com/marcnnn/ex_hdl_cores) | generic IP: FIFOs, CRC, arbiters, AXI4-Stream plumbing |
| [ex_hdl_xilinx](https://github.com/marcnnn/ex_hdl_xilinx) | Xilinx primitives, constraints, boards |
| [ex_net](https://github.com/marcnnn/ex_net) | Ethernet MAC, PCS, VLAN/IPv4/UDP/IGMP |
| [ex_ptp](https://github.com/marcnnn/ex_ptp) | IEEE 1588: timestamping, wallclock, servo, BMCA |
| [ex_aes67](https://github.com/marcnnn/ex_aes67) | RTP streams, jitter buffer, SAP/SDP, RTSP, mDNS, NMOS |
| [ex_audio](https://github.com/marcnnn/ex_audio) | audio DSP kernels: EQ, dynamics, matrix mixer, meters |
| [ex_pcie](https://github.com/marcnnn/ex_pcie) | PCIe DMA and BAR access, host side over vfio |

## Development

Sibling libraries come from a checkout next to this one when there is one
(`../exhdl` for ex_hdl, `../<name>` for the others), otherwise from GitHub.

```sh
mix test
```

## Interop

`mix test --only interop` runs the codecs and `ExPtp.Port` against real implementations (excluded
from `mix test`). Needs rootless podman and, for the first run, network access (image build, Wireshark
sample captures cached in `$TMPDIR/ex_interop_captures`; a failed download skips the test).

```sh
containers/build.sh            # tshark, linuxptp (ptp4l 4.2), beam (Elixir 1.18.3), nettools (tcpdump); Debian trixie
mix test --only interop        # about 9 minutes
```

The BEAM side of the ptp4l tests runs in an Elixir container on a podman network with `_build/<env>/lib`
mounted (`mix test` compiles first) and `ExPtp.Port` over `ExPtp.Transport.Udp` (`lib/ex_ptp/transport/udp.ex`): UDP/IPv4
multicast, `SO_TIMESTAMP` receive and pre-`sendto` transmit software timestamps, a software clock that the servo
steers on top of CLOCK_REALTIME, TAI by default. It declares software timestamps, so the port uses the
`:software` `ExPtp.Servo.Profile`. All containers share the host
kernel clock, so the port clock minus CLOCK_REALTIME is the true synchronisation error.

| Test | Against | Result |
|---|---|---|
| `tshark_test.exs` | tshark `-T json`: all ten message types (Sync, Delay_Req, Follow_Up, Delay_Resp, Pdelay_Req/Resp/Resp_Follow_Up, Announce with PATH_TRACE, Signaling, Management) over UDP (319/320, checksums verified), over Ethernet 0x88F7 and with an 802.1Q tag | no malformed or expert warnings, every header and body field and every flag equal, correctionField incl. negative and fractional, padded frames, a truncated message is flagged by Wireshark and rejected by `Message.decode/1` |
| `tshark_test.exs`, reverse | Wireshark samples `ptpv2.pcap` (Sync, Pdelay_Req, Announce) and `ptpv2_anon.pcapng`, converted by tshark | all messages decode and agree with tshark |
| `ptp4l_test.exs` (a) | ptp4l master (`--serverOnly`), `ExPtp.Port` slave, default and AES67 intervals | LISTENING, UNCALIBRATED, SLAVE; follows ptp4l's clockIdentity; median clock error 36 to 46 us, mean path delay 64 to 71 us. AES67 profile (8 Hz): SLAVE once, no state change afterwards (asserted) |
| (b) | `ExPtp.Port` master, ptp4l slave (`--clientOnly`) | ptp4l logs `LISTENING to UNCALIBRATED on RS_SLAVE`, `UNCALIBRATED to SLAVE on MASTER_CLOCK_SELECTED`, servo s0, s1, s2; median offset 36 to 38 us, path delay 64 to 67 us |
| (c1) to (c4) | BMCA: priority1 on either side, priority1 raised on ptp4l at run time with `pmc`, clockIdentity tie break (port identity just below or above ptp4l's) | the expected master on both sides in every case |
| (d) | tcpdump in ptp4l's namespace during (a) | every frame decodes with `ExPtp.Message` and matches Wireshark's fields |

What the setup needed and what it cannot do:

- ptp4l cannot adjust CLOCK_REALTIME in an unprivileged container and then never leaves servo state s0.
  `containers/linuxptp/fakeclock.c` (LD_PRELOAD) makes `clock_adjtime` succeed without touching the clock, so s1 and s2
  appear; ptp4l's offsets are the real offsets. ptp4l's software timestamp servo takes about 11 s to reach s2.
- A master that announces the PTP timescale must send TAI: the transport delivers it by default
  (`tai_offset_s: 37`, otherwise ptp4l reports 37 s offset). The slave side follows ptp4l's `-S` master, which
  announces an arbitrary timescale, so those tests start the transport with `timescale: :arb`.
- Software timestamps on a shared host: offsets are tens of microseconds with outliers up to milliseconds,
  so the assertions are loose (medians below 150 to 500 us).
- No peer delay, L2, one-step, hardware timestamps or other implementations, see NEEDS.md.
- Findings, all fixed: `time_source` default 0xA0, servo profile for software timestamps, transport in `lib/`,
  timescale of the transport.


## License

Apache-2.0, see `LICENSE`.
