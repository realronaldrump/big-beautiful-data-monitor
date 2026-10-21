#include "spawn_tty.h"

#include <fcntl.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <unistd.h>

extern char **environ;

pid_t bbdm_spawn_with_tty(const char *path, char *const argv[], const char *tty_path) {
    pid_t pid = fork();
    if (pid != 0) {
        return pid;
    }

    // Child. Only async-signal-safe calls from here until exec.
    // Signals this app blocks or ignores would carry over into nettop; restore the defaults
    // so SIGHUP still ends it.
    sigset_t none;
    sigemptyset(&none);
    sigprocmask(SIG_SETMASK, &none, NULL);
    struct sigaction standard = { .sa_handler = SIG_DFL };
    for (int sig = 1; sig < NSIG; sig++) {
        sigaction(sig, &standard, NULL);
    }

    if (setsid() < 0) {
        _exit(127);
    }
    // The first terminal a session leader opens becomes its controlling terminal;
    // TIOCSCTTY makes sure of it.
    int fd = open(tty_path, O_RDWR);
    if (fd < 0) {
        _exit(127);
    }
    ioctl(fd, TIOCSCTTY, 0);
    dup2(fd, STDIN_FILENO);
    dup2(fd, STDOUT_FILENO);
    dup2(fd, STDERR_FILENO);

    int limit = getdtablesize();
    if (limit > 65536) {
        limit = 65536;
    }
    for (int other = STDERR_FILENO + 1; other < limit; other++) {
        close(other);
    }

    execve(path, argv, environ);
    _exit(127);
}
