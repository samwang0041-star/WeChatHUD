#include <errno.h>
#include <limits.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    if (argc != 2 || argv[1][0] == '\0') {
        return 2;
    }

    int target_pid;
    if (argv[1][0] == '-' && argv[1][1] == '-' && argv[1][2] == 's' &&
        argv[1][3] == 'e' && argv[1][4] == 'l' && argv[1][5] == 'f' && argv[1][6] == '\0') {
        target_pid = getpid();
    } else {
        errno = 0;
        char *end = NULL;
        unsigned long parsed = strtoul(argv[1], &end, 10);
        if (errno == ERANGE || end == argv[1] || *end != '\0' || parsed == 0 || parsed > INT_MAX) {
            return 2;
        }
        target_pid = (int)parsed;
    }

    mach_port_t task = MACH_PORT_NULL;
    kern_return_t result = task_for_pid(mach_task_self(), target_pid, &task);
    int succeeded = result == KERN_SUCCESS;
    printf("%d %d\n", (int)result, succeeded);

    if (succeeded) {
        mach_port_deallocate(mach_task_self(), task);
    }
    return succeeded ? 0 : 1;
}
