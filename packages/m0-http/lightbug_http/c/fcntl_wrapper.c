/* Non-variadic wrappers for fcntl(2).
 *
 * fcntl is variadic: int fcntl(int fd, int cmd, ...).
 * On ARM64 macOS, variadic arguments use a different calling convention
 * (stack) than fixed arguments (registers). Mojo's external_call passes
 * all arguments as fixed, so the variadic arg never reaches fcntl.
 *
 * These wrappers have fixed signatures and call fcntl correctly via the
 * C compiler which handles the variadic ABI.
 */
#include <fcntl.h>

int fcntl_getfl(int fd) {
    return fcntl(fd, F_GETFL);
}

int fcntl_setfl(int fd, int flags) {
    return fcntl(fd, F_SETFL, flags);
}
