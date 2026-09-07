// Does one datagram into a socket with W blocked receivers cost more than
// with one? Each round: the loop sends one 8-byte datagram on the lane
// pair; whichever worker's recv returns sends a completion back. Reports
// CPU (user+sys, whole process) per round trip and which worker served,
// for W waiters. If the kernel wakes every waiter per datagram, CPU per
// round grows with W; if it wakes one, it does not.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/resource.h>
#include <unistd.h>

static int N = 100000, W = 1;
static int sub[2], comp[2];
static long served[64];

static double now_us(void) { struct timeval tv; gettimeofday(&tv, NULL); return tv.tv_sec * 1e6 + tv.tv_usec; }
static double cpu_us(void) { struct rusage r; getrusage(RUSAGE_SELF, &r); return (r.ru_utime.tv_sec + r.ru_stime.tv_sec) * 1e6 + r.ru_utime.tv_usec + r.ru_stime.tv_usec; }

static void *worker(void *a) {
    long id = (long)a; char b[8];
    for (;;) {
        if (recv(sub[0], b, 8, 0) != 8) abort();
        if (b[0] == 'q') return NULL;
        served[id]++;
        if (send(comp[1], b, 8, 0) != 8) abort();
    }
}

int main(int argc, char **argv) {
    if (argc > 1) W = atoi(argv[1]);
    if (argc > 2) N = atoi(argv[2]);
    if (socketpair(AF_UNIX, SOCK_DGRAM, 0, sub) || socketpair(AF_UNIX, SOCK_DGRAM, 0, comp)) { perror("socketpair"); return 1; }
    pthread_t t[64];
    for (long i = 0; i < W; i++) pthread_create(&t[i], NULL, worker, (void *)i);
    usleep(20000);
    char b[8] = {0};
    double c0 = cpu_us(), t0 = now_us();
    for (int i = 0; i < N; i++) {
        if (send(sub[1], b, 8, 0) != 8) abort();
        if (recv(comp[0], b, 8, 0) != 8) abort();
    }
    double t1 = now_us(), c1 = cpu_us();
    char q[8] = {'q'};
    for (int i = 0; i < W; i++) send(sub[1], q, 8, 0);
    for (int i = 0; i < W; i++) pthread_join(t[i], NULL);
    printf("W=%2d  %8.0f rt/s  wall %6.2f us/rt  cpu %6.2f us/rt  served:", W, N / ((t1 - t0) / 1e6), (t1 - t0) / N, (c1 - c0) / N);
    for (int i = 0; i < W; i++) printf(" %ld", served[i]);
    printf("\n");
    return 0;
}
