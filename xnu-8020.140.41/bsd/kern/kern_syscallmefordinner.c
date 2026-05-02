/*
 * kern_syscallmefordinner.c — custom syscall 552: pete_log
 *
 * Copies a userspace string into the kernel and emits it via kprintf.
 * Useful as a dead-simple demo that a custom syscall round-trip works.
 *
 * Callable from userspace:
 *   syscall(552, "hello kernel", 12);
 */

#include <sys/param.h>
#include <sys/systm.h>
#include <sys/sysproto.h>
#include <sys/proc.h>

#define PETE_LOG_MAX 255

int
pete_log(struct proc *p __unused, struct pete_log_args *uap, int32_t *retval __unused)
{
	char buf[PETE_LOG_MAX + 1];
	int error;
	user_size_t len;

	len = uap->len;
	if (len == 0 || len > PETE_LOG_MAX) {
		return EINVAL;
	}

	error = copyin(uap->msg, buf, (vm_size_t)len);
	if (error) {
		return error;
	}
	buf[len] = '\0';

	printf("[pete-dinner] %s\n", buf);

	return 0;
}
