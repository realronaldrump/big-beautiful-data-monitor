#ifndef SPAWN_TTY_H
#define SPAWN_TTY_H

#include <sys/types.h>

/// Starts `path` with `argv` as a new session leader whose controlling terminal, stdin, stdout and
/// stderr are the terminal at `tty_path`. Because the terminal is its controlling terminal, the
/// kernel sends the child SIGHUP when the other end closes, so it can never outlive this process.
/// (`posix_spawn` cannot attach a controlling terminal on macOS, and Swift cannot call `fork`.)
/// Returns the child's pid, or -1 with errno set.
pid_t bbdm_spawn_with_tty(const char *path, char *const argv[], const char *tty_path);

#endif
