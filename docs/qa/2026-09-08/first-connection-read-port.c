#include <errno.h>
#include <limits.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

static int parse_pid(const char *value, int *result) {
    if (strcmp(value, "--self") == 0) {
        *result = getpid();
        return 0;
    }

    errno = 0;
    char *end = NULL;
    unsigned long parsed = strtoul(value, &end, 10);
    if (errno == ERANGE || end == value || *end != '\0' || parsed == 0 || parsed > INT_MAX) {
        return -1;
    }
    *result = (int)parsed;
    return 0;
}

int main(int argc, char *argv[]) {
    if (argc != 2 || argv[1][0] == '\0') {
        return 2;
    }

    int target_pid;
    if (parse_pid(argv[1], &target_pid) != 0) {
        return 2;
    }

    mach_port_t task = MACH_PORT_NULL;
    errno = 0;
    int result = (int)syscall(SYS_task_read_for_pid, mach_task_self(), target_pid, &task);
    int saved_errno = errno;
    int succeeded = result == 0;
    printf("%d %d %d\n", result, saved_errno, succeeded);

    if (succeeded) {
        mach_port_deallocate(mach_task_self(), task);
    }
    return succeeded ? 0 : 1;
}
