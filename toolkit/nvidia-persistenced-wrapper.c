// nvidia-persistenced-wrapper is the entrypoint of the Talos service ext-nvidia-persistenced.
//
// It replaces the wrapper from siderolabs/extensions, which starts nvidia-persistenced and then
// only waits for SIGTERM. Talos starts the service as soon as /sys/bus/pci/drivers/nvidia exists.
// That directory appears partway through nvidia_init_module(), seconds before the driver
// registers its character devices. nvidia-persistenced started that early fails to initialize,
// exits, and removes /var/run/nvidia-persistenced, while the upstream wrapper keeps the service
// running, so Talos never restarts it.
//
// This wrapper:
//  1. waits until the driver lists "nvidiactl" in /proc/devices, the last step of
//     nvidia_init_module();
//  2. runs nvidia-persistenced, which forks the daemon and exits 0 only after the daemon has
//     initialized and created its socket;
//  3. adopts the daemon as child subreaper and forwards SIGTERM and SIGINT to it.
// It exits non-zero when nvidia-persistenced fails or the daemon dies, so `restart: always`
// retries.
//
// Talos runs each service start in a new PID namespace, so no daemon from an earlier run can
// still hold the PID file lock; unlike the upstream wrapper, this one kills nothing at startup.
#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define PERSISTENCED "/usr/local/bin/nvidia-persistenced"
#define PID_FILE "/var/run/nvidia-persistenced/nvidia-persistenced.pid"

static void logf_(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fputs("nvidia-persistenced-wrapper: ", stderr);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
}

static bool driver_ready(void)
{
    FILE *f = fopen("/proc/devices", "r");
    if (!f) {
        logf_("open /proc/devices: %s", strerror(errno));
        return false;
    }
    char line[128], name[64];
    unsigned major;
    bool ready = false;
    while (!ready && fgets(line, sizeof line, f))
        ready = sscanf(line, "%u %63s", &major, name) == 2 && strcmp(name, "nvidiactl") == 0;
    fclose(f);
    return ready;
}

static double seconds_since(const struct timespec *start)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (double)(now.tv_sec - start->tv_sec) + (double)(now.tv_nsec - start->tv_nsec) / 1e9;
}

static const char *describe(int status, char *buf, size_t size)
{
    if (WIFEXITED(status))
        snprintf(buf, size, "exit status %d", WEXITSTATUS(status));
    else
        snprintf(buf, size, "signal %d", WTERMSIG(status));
    return buf;
}

static pid_t read_daemon_pid(void)
{
    FILE *f = fopen(PID_FILE, "r");
    if (!f) {
        logf_("open %s: %s", PID_FILE, strerror(errno));
        return -1;
    }
    int pid;
    if (fscanf(f, "%d", &pid) != 1 || pid <= 1) {
        logf_("%s holds no daemon PID", PID_FILE);
        pid = -1;
    }
    fclose(f);
    return pid;
}

int main(int argc, char *argv[])
{
    (void)argc;
    // The handled signals stay blocked and are taken with sigwaitinfo, which also works as PID 1.
    // The child restores the original mask: nvidia-persistenced must receive SIGTERM.
    sigset_t handled, original;
    sigemptyset(&handled);
    sigaddset(&handled, SIGCHLD);
    sigaddset(&handled, SIGINT);
    sigaddset(&handled, SIGTERM);
    if (sigprocmask(SIG_BLOCK, &handled, &original) != 0 || prctl(PR_SET_CHILD_SUBREAPER, 1) != 0) {
        logf_("setup: %s", strerror(errno));
        return 1;
    }

    struct timespec start;
    clock_gettime(CLOCK_MONOTONIC, &start);
    if (!driver_ready()) {
        logf_("waiting for the NVIDIA driver to register nvidiactl");
        const struct timespec interval = {.tv_sec = 0, .tv_nsec = 100 * 1000 * 1000};
        do {
            int sig = sigtimedwait(&handled, NULL, &interval);
            if (sig == SIGINT || sig == SIGTERM)
                return 0;
        } while (!driver_ready());
        logf_("NVIDIA driver ready after %.1f s", seconds_since(&start));
    }

    pid_t launcher = fork();
    if (launcher < 0) {
        logf_("fork: %s", strerror(errno));
        return 1;
    }
    if (launcher == 0) {
        sigprocmask(SIG_SETMASK, &original, NULL);
        argv[0] = (char *)PERSISTENCED;
        execv(PERSISTENCED, argv);
        logf_("exec %s: %s", PERSISTENCED, strerror(errno));
        _exit(127);
    }

    pid_t daemon = 0;
    int stop = 0; // SIGINT or SIGTERM once a stop was requested
    char why[32];
    for (;;) {
        int sig = sigwaitinfo(&handled, NULL);
        if (sig < 0) {
            if (errno == EINTR)
                continue;
            logf_("sigwaitinfo: %s", strerror(errno));
            return 1;
        }
        if (sig != SIGCHLD) {
            stop = sig;
            if (daemon > 0)
                kill(daemon, sig);
            continue;
        }
        int status;
        pid_t pid;
        while ((pid = waitpid(-1, &status, WNOHANG)) > 0) {
            if (pid == launcher) {
                if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
                    logf_("nvidia-persistenced failed to start (%s)", describe(status, why, sizeof why));
                    return stop ? 0 : 1;
                }
                // The daemon wrote its PID file before reporting success to the launcher.
                daemon = read_daemon_pid();
                if (daemon < 0 || kill(daemon, 0) != 0) {
                    logf_("nvidia-persistenced daemon is not running");
                    return stop ? 0 : 1;
                }
                if (stop)
                    kill(daemon, stop);
                else
                    logf_("nvidia-persistenced running as PID %d", daemon);
            } else if (pid == daemon) {
                if (stop)
                    return 0;
                logf_("nvidia-persistenced exited (%s)", describe(status, why, sizeof why));
                return 1;
            }
        }
    }
}
