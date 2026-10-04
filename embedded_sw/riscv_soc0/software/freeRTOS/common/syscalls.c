/*
 * Minimal syscall implementations for bare-metal RISC-V systems
 * These stubs satisfy the newlib requirements without emitting warnings
 */

#include <errno.h>
#include <sys/stat.h>
#include <sys/times.h>
#include <sys/unistd.h>

#undef errno
extern int errno;

/* Close a file - always fail in bare-metal */
int _close(int file) {
    errno = EBADF;
    return -1;
}

/* Query whether output stream is a terminal - always no in bare-metal */
int _isatty(int file) {
    return 0;
}

/* Set position in a file - always fail in bare-metal */
int _lseek(int file, int ptr, int dir) {
    errno = EBADF;
    return -1;
}

/* Read from a file - always fail in bare-metal unless stdin is implemented */
int _read(int file, char *ptr, int len) {
    errno = EBADF;
    return -1;
}

/* Status of an open file - minimal implementation */
int _fstat(int file, struct stat *st) {
    st->st_mode = S_IFCHR;
    return 0;
}

/* Write to a file - minimal stub that discards output */
/* Override this function if you want stdout/stderr to go to UART */
int _write(int file, char *ptr, int len) {
    /* For now, just pretend we wrote everything */
    /* In a real implementation, you'd send to UART here */
    return len;
}

/* Get process ID - return fixed value in bare-metal */
int _getpid(void) {
    return 1;
}

/* Send signal to process - always fail in bare-metal */
int _kill(int pid, int sig) {
    errno = EINVAL;
    return -1;
}
