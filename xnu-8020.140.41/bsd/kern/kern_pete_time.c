/*
 * kern_pete_time.c — custom syscall 553: pete_gettimeofday
 *
 * A clone of gettimeofday(2) with a live-tunable sysctl offset:
 *   kern.pete_time_skew  (seconds, default 0, read/write)
 *
 * Callable from userspace:
 *   struct timeval tv;
 *   syscall(553, &tv, NULL);
 *
 * To apply a skew without rebooting:
 *   sudo sysctl -w kern.pete_time_skew=3600
 */

#include <sys/param.h>
#include <sys/systm.h>
#include <sys/sysproto.h>
#include <sys/proc_internal.h>
#include <sys/time.h>
#include <sys/sysctl.h>
#include <kern/clock.h>

static int pete_time_skew = 0;
SYSCTL_INT(_kern, OID_AUTO, pete_time_skew,
    CTLFLAG_RW | CTLFLAG_LOCKED,
    &pete_time_skew, 0, "pete_gettimeofday skew in seconds");

int
pete_gettimeofday(struct proc *p, struct pete_gettimeofday_args *uap,
    __unused int32_t *retval)
{
	int error = 0;
	clock_sec_t secs;
	clock_usec_t usecs;

	if (uap->tp) {
		clock_gettimeofday(&secs, &usecs);
		secs += pete_time_skew;

		if (IS_64BIT_PROCESS(p)) {
			struct user64_timeval user_atv = {};
			user_atv.tv_sec = (uint32_t)secs;
			user_atv.tv_usec = usecs;
			error = copyout(&user_atv, uap->tp, sizeof(user_atv));
		} else {
			struct user32_timeval user_atv = {};
			user_atv.tv_sec = (uint32_t)secs;
			user_atv.tv_usec = usecs;
			error = copyout(&user_atv, uap->tp, sizeof(user_atv));
		}
		if (error) {
			return error;
		}
	}

	/* tzp is accepted but always zeroed — timezone has been deprecated
	 * since POSIX.1-2008; callers should not rely on its value. */
	if (uap->tzp) {
		struct timezone zero_tz = {};
		error = copyout(&zero_tz, CAST_USER_ADDR_T(uap->tzp), sizeof(zero_tz));
	}

	return error;
}
