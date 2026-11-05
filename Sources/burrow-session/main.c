// sudo caches credentials per controlling terminal. Giving the program a
// pseudo-terminal as that terminal, with its standard streams left piped, lets
// one password cover its whole process tree while it stays non-interactive.
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>

static volatile pid_t child_group = 0;
static volatile sig_atomic_t terminate_requests = 0;

static void forward_signal(int signal_number) {
    if (child_group <= 0) {
        return;
    }
    if (signal_number == SIGTERM && ++terminate_requests > 1) {
        signal_number = SIGKILL;
    }
    if (kill(-child_group, signal_number) < 0) {
        kill(child_group, signal_number);
    }
}

static void run_in_new_session(const char *terminal_path, char *program[], const sigset_t *signal_mask) {
    if (setsid() < 0) {
        fprintf(stderr, "burrow-session: setsid failed: %s\n", strerror(errno));
        _exit(71);
    }
    if (strcmp(terminal_path, "-") != 0) {
        int terminal = open(terminal_path, O_RDWR | O_NOCTTY);
        if (terminal < 0) {
            fprintf(stderr, "burrow-session: cannot open %s: %s\n", terminal_path, strerror(errno));
            _exit(66);
        }
        if (ioctl(terminal, TIOCSCTTY, 0) < 0) {
            fprintf(stderr, "burrow-session: cannot attach %s: %s\n", terminal_path, strerror(errno));
            _exit(71);
        }
        close(terminal);
    }
    sigprocmask(SIG_SETMASK, signal_mask, NULL);
    execvp(program[0], program);
    fprintf(stderr, "burrow-session: cannot run %s: %s\n", program[0], strerror(errno));
    _exit(126);
}

// The launcher already makes this process a group leader, which setsid refuses,
// so the program runs in a forked child and this process relays signals to it.
// Relayed signals stay blocked until both sides are ready, so none is lost or fatal.
int main(int argc, char *argv[]) {
    if (argc < 3) {
        fprintf(stderr, "usage: burrow-session <tty-path|-> <program> [arguments...]\n");
        return 64;
    }

    sigset_t relayed, previous;
    sigemptyset(&relayed);
    sigaddset(&relayed, SIGINT);
    sigaddset(&relayed, SIGTERM);
    sigaddset(&relayed, SIGHUP);
    sigaddset(&relayed, SIGQUIT);
    sigprocmask(SIG_BLOCK, &relayed, &previous);

    pid_t child = fork();
    if (child < 0) {
        fprintf(stderr, "burrow-session: fork failed: %s\n", strerror(errno));
        return 71;
    }
    if (child == 0) {
        run_in_new_session(argv[1], &argv[2], &previous);
    }

    child_group = child;
    struct sigaction relay = {0};
    relay.sa_handler = forward_signal;
    sigemptyset(&relay.sa_mask);
    sigaction(SIGINT, &relay, NULL);
    sigaction(SIGTERM, &relay, NULL);
    sigaction(SIGHUP, &relay, NULL);
    sigaction(SIGQUIT, &relay, NULL);
    sigprocmask(SIG_SETMASK, &previous, NULL);

    int status = 0;
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) {
            return 71;
        }
    }
    if (WIFSIGNALED(status)) {
        return 128 + WTERMSIG(status);
    }
    return WEXITSTATUS(status);
}
