/*
 * mem_worker_grow.c - Gradually-growing memory worker for OOM killer experiments
 *
 * Usage: ./mem_worker_grow <name> <step_mb> <step_interval_ms> <max_mb>
 *
 * Allocates memory incrementally in step_mb chunks, touching every page in
 * each chunk before sleeping step_interval_ms, until max_mb total is reached.
 * Pages are written with a unique pattern (pid ^ step ^ page_index) to ensure
 * they are faulted in, dirty, and not subject to KSM merging.
 *
 * After reaching max_mb, holds all allocations and waits in pause() loop.
 *
 * SIGTERM: logs and exits (same pattern as mem_worker.c).
 * SIGKILL (OOM): logged by kernel; controller detects via waitpid.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/mman.h>
#include <time.h>

#define PAGE_SIZE 4096

static const char *g_name = "?";

static void sigterm_handler(int sig) {
    fprintf(stderr, "[grow_worker:%s] PID=%d received signal %d, exiting.\n",
            g_name, (int)getpid(), sig);
    fflush(stderr);
    exit(1);
}

static void sleep_ms(long ms) {
    struct timespec ts;
    ts.tv_sec  = ms / 1000;
    ts.tv_nsec = (ms % 1000) * 1000000L;
    nanosleep(&ts, NULL);
}

int main(int argc, char *argv[]) {
    if (argc != 5) {
        fprintf(stderr, "Usage: %s <name> <step_mb> <step_interval_ms> <max_mb>\n", argv[0]);
        return 1;
    }

    g_name                  = argv[1];
    long step_mb            = atol(argv[2]);
    long step_interval_ms   = atol(argv[3]);
    long max_mb             = atol(argv[4]);

    if (step_mb <= 0 || step_interval_ms < 0 || max_mb <= 0) {
        fprintf(stderr, "[grow_worker:%s] Invalid arguments.\n", g_name);
        return 1;
    }

    signal(SIGTERM, sigterm_handler);

    pid_t pid = getpid();
    long step_bytes = step_mb * 1024L * 1024L;
    long max_bytes  = max_mb  * 1024L * 1024L;
    long total_allocated = 0;
    int  step = 0;

    printf("[grow_worker:%s] PID=%d start: step=%ldMB interval=%ldms max=%ldMB\n",
           g_name, (int)pid, step_mb, step_interval_ms, max_mb);
    fflush(stdout);

    while (total_allocated < max_bytes) {
        long chunk = step_bytes;
        if (total_allocated + chunk > max_bytes)
            chunk = max_bytes - total_allocated;

        char *mem = mmap(NULL, (size_t)chunk,
                         PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANONYMOUS,
                         -1, 0);
        if (mem == MAP_FAILED) {
            perror("[grow_worker] mmap failed");
            /* Likely OOM — just exit; controller detects SIGKILL separately */
            return 1;
        }

        /* Touch every page: write pid ^ step ^ page_index to guarantee RSS */
        long pages = chunk / PAGE_SIZE;
        for (long p = 0; p < pages; p++) {
            mem[p * PAGE_SIZE] = (char)((pid) ^ step ^ (int)p);
        }

        total_allocated += chunk;
        step++;

        printf("[grow_worker:%s] PID=%d step=%d allocated %ldMB / %ldMB\n",
               g_name, (int)pid, step,
               total_allocated / (1024L * 1024L), max_mb);
        fflush(stdout);

        if (total_allocated < max_bytes)
            sleep_ms(step_interval_ms);
    }

    printf("[grow_worker:%s] PID=%d reached max %ldMB. Holding...\n",
           g_name, (int)pid, max_mb);
    fflush(stdout);

    /* Hold all allocations and wait to be killed */
    while (1) {
        pause();
    }

    /* Never reached */
    return 0;
}
