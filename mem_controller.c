/*
 * mem_controller.c - OOM pattern controller for Experiment 03
 *
 * Usage: ./mem_controller <worker_binary> <worker_max_mb> <num_cycles> <log_file>
 *        [container_id] [trial_id]
 *
 * Spawns NUM_WORKERS (4) instances of worker_binary via fork+exec, each
 * growing to worker_max_mb MB. Monitors them every 500ms with waitpid(WNOHANG).
 * When a worker is OOM-killed (SIGKILL), logs the event and immediately
 * respawns that slot. Exits after num_cycles total OOM events.
 *
 * The controller must be placed in its target cgroup *before* it spawns
 * workers — children inherit the cgroup automatically (cgroups v2).
 *
 * The shell script sets oom_score_adj=-500 on the controller to protect it.
 *
 * Log format (one event per line):
 *   CONTROLLER_START ts=... container=C trial=T max_mb=M num_cycles=N
 *   SPAWN slot=S gen=G pid=P ts=...
 *   KILL  cycle=N slot=S gen=G pid=P sig=9 lifetime=X.Xs ts=...
 *   CONTROLLER_END total_cycles=N kill_sequence=S0,S1,... ts=...
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <errno.h>

#define NUM_WORKERS 4
#define POLL_MS     500

typedef struct {
    int    slot;        /* 0-3, stable across respawns */
    pid_t  pid;
    int    generation;  /* increments on each respawn   */
    time_t spawn_time;
} WorkerSlot;

static FILE       *g_log  = NULL;
static const char *g_worker_binary = NULL;
static long        g_worker_max_mb = 0;

/* ---- helpers ----------------------------------------------------------- */

static double now_ts(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void log_line(const char *fmt, ...) {
    va_list ap;
    /* stdout */
    va_start(ap, fmt); vprintf(fmt, ap); va_end(ap);
    fflush(stdout);
    /* log file */
    if (g_log) {
        va_start(ap, fmt); vfprintf(g_log, fmt, ap); va_end(ap);
        fflush(g_log);
    }
}

static void sleep_ms(long ms) {
    struct timespec ts;
    ts.tv_sec  = ms / 1000;
    ts.tv_nsec = (ms % 1000) * 1000000L;
    nanosleep(&ts, NULL);
}

/* ---- worker spawn ------------------------------------------------------ */

static pid_t spawn_worker(int slot, int generation) {
    /*
     * Name encodes slot+generation so it's visible in ps / dmesg.
     * Args: <name> <step_mb> <step_interval_ms> <max_mb>
     * step_mb=10, step_interval_ms=200 (gradual growth).
     */
    char name[64];
    snprintf(name, sizeof(name), "slot%d-gen%d", slot, generation);

    char max_mb_str[32];
    snprintf(max_mb_str, sizeof(max_mb_str), "%ld", g_worker_max_mb);

    pid_t pid = fork();
    if (pid < 0) {
        perror("fork");
        return -1;
    }

    if (pid == 0) {
        /* child: exec the grow worker */
        execl(g_worker_binary, g_worker_binary,
              name, "10", "200", max_mb_str,
              (char *)NULL);
        perror("execl");
        _exit(127);
    }

    return pid;
}

/* ---- main -------------------------------------------------------------- */

int main(int argc, char *argv[]) {
    if (argc < 5) {
        fprintf(stderr,
            "Usage: %s <worker_binary> <worker_max_mb> <num_cycles> <log_file>"
            " [container_id] [trial_id]\n", argv[0]);
        return 1;
    }

    g_worker_binary    = argv[1];
    g_worker_max_mb    = atol(argv[2]);
    int num_cycles     = atoi(argv[3]);
    const char *logpath = argv[4];
    int container_id   = (argc >= 6) ? atoi(argv[5]) : 0;
    int trial_id       = (argc >= 7) ? atoi(argv[6]) : 0;

    /* Open log file */
    g_log = fopen(logpath, "w");
    if (!g_log) {
        perror("fopen log");
        return 1;
    }

    /* Protect this controller from OOM */
    {
        char path[128];
        snprintf(path, sizeof(path), "/proc/%d/oom_score_adj", (int)getpid());
        FILE *f = fopen(path, "w");
        if (f) { fprintf(f, "-500\n"); fclose(f); }
    }

    log_line("CONTROLLER_START ts=%.3f container=%d trial=%d max_mb=%ld num_cycles=%d\n",
             now_ts(), container_id, trial_id, g_worker_max_mb, num_cycles);

    /* Initialize and spawn all worker slots */
    WorkerSlot slots[NUM_WORKERS];
    for (int i = 0; i < NUM_WORKERS; i++) {
        slots[i].slot       = i;
        slots[i].generation = 0;
        slots[i].pid        = spawn_worker(i, 0);
        slots[i].spawn_time = time(NULL);
        log_line("SPAWN slot=%d gen=0 pid=%d ts=%.3f\n",
                 i, (int)slots[i].pid, now_ts());
    }

    /* kill_sequence accumulation */
    int kill_sequence[1024];
    int total_kills = 0;

    while (total_kills < num_cycles) {
        sleep_ms(POLL_MS);

        for (int i = 0; i < NUM_WORKERS; i++) {
            if (slots[i].pid <= 0) continue;

            int status = 0;
            pid_t ret = waitpid(slots[i].pid, &status, WNOHANG);

            if (ret == 0) continue;   /* still running */

            if (ret < 0) {
                if (errno == ECHILD) {
                    /* already reaped — shouldn't happen, but handle */
                    slots[i].pid = -1;
                }
                continue;
            }

            /* Worker exited — check if OOM-killed */
            if (WIFSIGNALED(status) && WTERMSIG(status) == SIGKILL) {
                double lifetime = difftime(time(NULL), slots[i].spawn_time);
                total_kills++;
                kill_sequence[total_kills - 1] = slots[i].slot;

                log_line("KILL cycle=%d slot=%d gen=%d pid=%d sig=9 lifetime=%.1fs ts=%.3f\n",
                         total_kills,
                         slots[i].slot,
                         slots[i].generation,
                         (int)slots[i].pid,
                         lifetime,
                         now_ts());

                /* Respawn immediately */
                slots[i].generation++;
                slots[i].pid        = spawn_worker(slots[i].slot, slots[i].generation);
                slots[i].spawn_time = time(NULL);

                log_line("SPAWN slot=%d gen=%d pid=%d ts=%.3f\n",
                         slots[i].slot,
                         slots[i].generation,
                         (int)slots[i].pid,
                         now_ts());

                if (total_kills >= num_cycles) break;

            } else if (WIFEXITED(status)) {
                /*
                 * Worker exited normally (e.g., mmap failed under pressure).
                 * Not a clean OOM kill, but respawn anyway to keep the slot alive.
                 */
                log_line("EXIT slot=%d gen=%d pid=%d code=%d ts=%.3f\n",
                         slots[i].slot,
                         slots[i].generation,
                         (int)slots[i].pid,
                         WEXITSTATUS(status),
                         now_ts());
                slots[i].generation++;
                slots[i].pid        = spawn_worker(slots[i].slot, slots[i].generation);
                slots[i].spawn_time = time(NULL);
                log_line("SPAWN slot=%d gen=%d pid=%d ts=%.3f\n",
                         slots[i].slot,
                         slots[i].generation,
                         (int)slots[i].pid,
                         now_ts());
            }
            /* Other signals (e.g., SIGTERM from cleanup): just note */
        }
    }

    /* Build kill_sequence string */
    char seq_buf[4096];
    int  pos = 0;
    for (int i = 0; i < total_kills && pos < (int)sizeof(seq_buf) - 4; i++) {
        if (i > 0) seq_buf[pos++] = ',';
        pos += snprintf(seq_buf + pos, sizeof(seq_buf) - pos, "%d", kill_sequence[i]);
    }
    seq_buf[pos] = '\0';

    log_line("CONTROLLER_END total_cycles=%d kill_sequence=%s ts=%.3f\n",
             total_kills, seq_buf, now_ts());

    /* Clean up remaining workers */
    for (int i = 0; i < NUM_WORKERS; i++) {
        if (slots[i].pid > 0) {
            kill(slots[i].pid, SIGTERM);
            waitpid(slots[i].pid, NULL, 0);
        }
    }

    if (g_log) fclose(g_log);
    return 0;
}
