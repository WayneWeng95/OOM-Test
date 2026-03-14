/*
 * mem_worker.c - Memory allocation worker for OOM killer experiments
 *
 * Usage: ./mem_worker <name> <megabytes>
 *
 * Allocates the specified amount of memory, touches every page to ensure
 * it's actually resident (RSS, not just virtual), then sleeps forever.
 *
 * The OOM killer decides based on RSS, so we must fault in every page.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/mman.h>

#define PAGE_SIZE 4096

/* Signal handler so we can see which process got the OOM signal */
void sigterm_handler(int sig) {
    fprintf(stderr, "[worker] Received signal %d, exiting.\n", sig);
    exit(1);
}

int main(int argc, char *argv[]) {
    if (argc != 3) {
        fprintf(stderr, "Usage: %s <name> <megabytes>\n", argv[0]);
        return 1;
    }

    const char *name = argv[1];
    long mb = atol(argv[2]);
    long bytes = mb * 1024L * 1024L;

    signal(SIGTERM, sigterm_handler);

    printf("[worker:%s] PID=%d, allocating %ld MB...\n", name, getpid(), mb);

    /*
     * Use mmap instead of malloc for more predictable behavior.
     * MAP_POPULATE pre-faults all pages so RSS is immediately correct.
     * MAP_ANONYMOUS gives us zero-filled memory not backed by a file.
     */
    char *mem = mmap(NULL, bytes,
                     PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS | MAP_POPULATE,
                     -1, 0);

    if (mem == MAP_FAILED) {
        perror("[worker] mmap failed");
        return 1;
    }

    /*
     * Write a unique pattern to every page to guarantee the pages are
     * faulted in and dirty. This prevents the kernel from merging them
     * (KSM) or reclaiming them as clean pages.
     */
    for (long i = 0; i < bytes; i += PAGE_SIZE) {
        mem[i] = (char)(i ^ getpid());
    }

    printf("[worker:%s] PID=%d, allocated and touched %ld MB. Holding...\n",
           name, getpid(), mb);

    /* Hold the memory and wait to be killed */
    while (1) {
        pause();  /* Sleep until signal */
    }

    /* Never reached */
    munmap(mem, bytes);
    return 0;
}
