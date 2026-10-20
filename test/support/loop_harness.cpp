// Closed loop harness for ptp_loop (test/support/loop_bench.ex).
// Plays network and software around two wallclocks on unrelated clocks:
//   Sync:      master captures t1 at the first master edge at/after the send time (cap bit 0),
//              slave captures t2 at the first slave edge at/after arrival (delay + jitter)
//   Delay_Req: slave captures t3 (cap bit 1) `turn` later, master captures t4 after delay + jitter
//   software:  t1 and t4 are handed over like message payloads, then `calc` starts the offset
//              calculation (RTL), which feeds the servo (RTL) and the slave's rate (RTL).
// Time is in femtoseconds, so a few ppb of clock error are exact integers.
// usage: sim n_intervals interval_ns seed delay_ns jitter_ns master_ppb slave_ppb tick_ns init_offset_ns
//            kp ki thr thr_unlock needed step_thr turn_ns
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <memory>
#include <random>

#include "Vtop.h"
#include "verilated.h"

typedef int64_t i64;
typedef uint64_t u64;
static const i64 FS = 1000000; // fs per ns

enum { PEND_M0, PEND_S0, PEND_S1, PEND_M1, DELIVER, LOG, START };

int main(int argc, char** argv) {
  if (argc != 17) { std::fprintf(stderr, "bad arguments\n"); return 1; }
  i64 n_int = atoll(argv[1]), interval = atoll(argv[2]) * FS, seed = atoll(argv[3]);
  i64 delay = atoll(argv[4]) * FS, jitter = atoll(argv[5]) * FS;
  i64 ppb_m = atoll(argv[6]), ppb_s = atoll(argv[7]), tick = atoll(argv[8]);
  i64 init_off = atoll(argv[9]);
  i64 kp = atoll(argv[10]), ki = atoll(argv[11]), thr = atoll(argv[12]), thr_unlock = atoll(argv[13]);
  i64 needed = atoll(argv[14]), step_thr = atoll(argv[15]), turn = atoll(argv[16]) * FS;

  auto ctx = std::make_unique<VerilatedContext>();
  auto top = std::make_unique<Vtop>(ctx.get());
  std::mt19937_64 rng(seed);
  auto jit = [&]() { return jitter ? (i64)(rng() % (u64)(jitter + 1)) : 0; };

  i64 p_nom = tick * FS;
  i64 Pm = (i64)((__int128)p_nom * 1000000000 / (1000000000 + ppb_m));
  i64 Ps = (i64)((__int128)p_nom * 1000000000 / (1000000000 + ppb_s));
  Pm &= ~1LL; Ps &= ~1LL;
  i64 nm = 3 * Pm / 4, ns = Ps / 3;  // unrelated phases
  i64 nm_fall = -1, ns_fall = -1;
  bool m_clk = 0, s_clk = 0;
  std::multimap<i64, int> sched;
  sched.insert({20000 * FS, START});

  top->clk_m = 0; top->clk_s = 0; top->rst_m_n = 0; top->rst_s_n = 0;
  top->m_set_wr = 0; top->m_cap = 0; top->s_set_wr = 0; top->s_cap = 0; top->calc = 0; top->load = 0;
  top->kp = kp & 0xFFFFFF; top->ki = ki & 0xFFFFFF;
  top->thr = thr; top->thr_unlock = thr_unlock; top->needed = needed; top->step_thr = step_thr;
  top->eval();

  int pend_m = 0, pend_s = 0, applied_m = 0, applied_s = 0;
  bool deliver = false;
  u64 t1s = 0, t1n = 0, t1f = 0, t4s = 0, t4n = 0, t4f = 0;
  long cyc_m = 0, cyc_s = 0, k = 0, stepped = 0, dropped = 0, nerr = 0;
  // last readings and their edge times
  i64 m_read = 0, s_read = 0, m_edge = 0, s_edge = 0;
  i64 ppb_last = 0;
  i64 end_time = (n_int + 1) * interval + 50000 * FS;

  for (;;) {
    i64 t = nm, kind = 0;  // 0 m rise, 1 m fall, 2 s rise, 3 s fall, 4 scheduled
    if (nm_fall >= 0 && nm_fall < t) { t = nm_fall; kind = 1; }
    if (ns < t) { t = ns; kind = 2; }
    if (ns_fall >= 0 && ns_fall < t) { t = ns_fall; kind = 3; }
    if (!sched.empty() && sched.begin()->first <= t) { t = sched.begin()->first; kind = 4; }
    if (t > end_time) break;

    if (kind == 4) {
      int a = sched.begin()->second;
      sched.erase(sched.begin());
      switch (a) {
        case START:
          sched.insert({t, PEND_M0});
          break;
        case PEND_M0:
          pend_m |= 1;
          if (k + 1 < n_int + 1) sched.insert({t + interval, PEND_M0});
          sched.insert({t + interval - 500 * FS * 1000, LOG});
          break;
        case PEND_S0: pend_s |= 1; break;
        case PEND_S1: pend_s |= 2; break;
        case PEND_M1: pend_m |= 2; break;
        case DELIVER: deliver = true; break;
        case LOG: {
          double off = (double)(s_read - m_read) + (double)(m_edge - s_edge) / FS;
          std::printf("S %ld %.3f %lld %d\n", k, off, (long long)ppb_last, (int)top->x_locked);
          k++;
          break;
        }
      }
      continue;
    }

    if (kind == 0) {  // master rising edge
      cyc_m++;
      if (cyc_m == 3) top->rst_m_n = 1;
      top->m_set_wr = 0;
      if (cyc_m == 6) {
        top->m_set_wr = 1; top->m_set_sec = 1000; top->m_set_ns = 0;
      }
      top->m_cap = pend_m; applied_m = pend_m; pend_m = 0;
      m_clk = 1; top->clk_m = 1; top->eval();
      m_read = (i64)top->x_m_now_sec * 1000000000LL + (i64)top->x_m_now_ns;
      m_edge = t;
      if (applied_m & 1) {
        t1s = top->x_m_cap0_sec; t1n = top->x_m_cap0_ns; t1f = top->x_m_cap0_frac >> 16;
        sched.insert({t + delay + jit(), PEND_S0});
      }
      if (applied_m & 2) {
        t4s = top->x_m_cap1_sec; t4n = top->x_m_cap1_ns; t4f = top->x_m_cap1_frac >> 16;
        sched.insert({t + 300000 * FS, DELIVER});
      }
      nm_fall = t + Pm / 2; nm = t + Pm;
    } else if (kind == 1) {
      top->m_cap = 0; top->m_set_wr = 0; top->clk_m = 0; top->eval(); nm_fall = -1;
    } else if (kind == 2) {  // slave rising edge
      cyc_s++;
      if (cyc_s == 3) top->rst_s_n = 1;
      top->s_set_wr = 0; top->load = 0; top->calc = 0;
      if (cyc_s == 6) {
        top->s_set_wr = 1; top->s_set_sec = 1000; top->s_set_ns = (u64)init_off;
        top->load = 1;
      }
      if (deliver) {
        top->t1_sec = t1s; top->t1_ns = t1n; top->t1_frac = t1f;
        top->t4_sec = t4s; top->t4_ns = t4n; top->t4_frac = t4f;
        top->calc = 1; deliver = false;
      }
      top->s_cap = pend_s; applied_s = pend_s; pend_s = 0;
      s_clk = 1; top->clk_s = 1; top->eval();
      s_read = (i64)top->x_s_now_sec * 1000000000LL + (i64)top->x_s_now_ns;
      s_edge = t;
      if (applied_s & 1) sched.insert({t + turn, PEND_S1});
      if (applied_s & 2) sched.insert({t + delay + jit(), PEND_M1});
      if (top->x_off_valid) {
        int32_t e = (int32_t)top->x_off_err;
        double off = (double)(s_read - m_read) + (double)(m_edge - s_edge) / FS;
        std::printf("E %lld %.3f %d\n", (long long)(t / FS), off, e);
        nerr++;
      }
      if (top->x_stepped) stepped++;
      if (top->x_dropped) dropped++;
      if (top->x_ppb_valid) { int32_t p = (int32_t)(top->x_ppb << 4) >> 4; ppb_last = p; }
      ns_fall = t + Ps / 2; ns = t + Ps;
    } else {
      top->s_cap = 0; top->s_set_wr = 0; top->load = 0; top->calc = 0; top->clk_s = 0; top->eval(); ns_fall = -1;
    }
  }
  std::printf("D %ld %ld %ld %ld %ld %ld\n", cyc_m, cyc_s, stepped, dropped, nerr, (long)top->x_range_err);
  top->final();
  return 0;
}
