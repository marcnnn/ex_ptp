/* LD_PRELOAD shim for unprivileged containers: ptp4l cannot adjust CLOCK_REALTIME
 * without CAP_SYS_TIME, and treats a failed adjustment as a servo failure (it resets
 * the servo, which then never leaves state s0). The shim reports success for every
 * clock_adjtime call that would change the clock and leaves the clock alone, so the
 * servo runs through s0, s1, s2 and ptp4l logs the offsets it measures. Reads
 * (modes == 0) go to the kernel. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <sys/timex.h>
#include <time.h>

int clock_adjtime(clockid_t id, struct timex *tx)
{
	static int (*real)(clockid_t, struct timex *);
	if (!real)
		real = dlsym(RTLD_NEXT, "clock_adjtime");
	if (tx->modes == 0)
		return real(id, tx);
	return 0;
}

int clock_settime(clockid_t id, const struct timespec *ts)
{
	return 0;
}
