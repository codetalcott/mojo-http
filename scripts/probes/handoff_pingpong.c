// Cost of one loop<->worker handoff on this machine, by primitive.
// dgram: two SOCK_DGRAM socketpairs, blocking recv both sides (m0serve's pool shape)
// dgramk: same, but the loop side parks in kevent then recv's until EAGAIN (the loop's shape)
// condvar: pthread mutex+cond ping-pong
// spin: atomic flag ping-pong (no syscalls)
// Each reports round trips/s, wall us per round trip, and CPU us (user+sys, both threads) per round trip.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <stdatomic.h>
#include <sys/socket.h>
#include <sys/event.h>
#include <sys/time.h>
#include <sys/resource.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <mach/mach_time.h>

static int N = 200000;
static int sub[2], comp[2];
static _Atomic int flag;
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cv_l = PTHREAD_COND_INITIALIZER, cv_w = PTHREAD_COND_INITIALIZER;
static int turn; // 0 = loop's, 1 = worker's

static double now_us(void) { struct timeval tv; gettimeofday(&tv, NULL); return tv.tv_sec * 1e6 + tv.tv_usec; }
static double cpu_us(void) { struct rusage r; getrusage(RUSAGE_SELF, &r); return (r.ru_utime.tv_sec + r.ru_stime.tv_sec) * 1e6 + r.ru_utime.tv_usec + r.ru_stime.tv_usec; }

static void *w_dgram(void *a) { char b[8]; for (int i = 0; i < N; i++) { if (recv(sub[0], b, 8, 0) != 8) abort(); if (send(comp[1], b, 8, 0) != 8) abort(); } return NULL; }
static void *w_cond(void *a) { for (int i = 0; i < N; i++) { pthread_mutex_lock(&mu); while (turn != 1) pthread_cond_wait(&cv_w, &mu); turn = 0; pthread_cond_signal(&cv_l); pthread_mutex_unlock(&mu); } return NULL; }
static void *w_spin(void *a) { for (int i = 0; i < N; i++) { while (atomic_load_explicit(&flag, memory_order_acquire) != 1) ; atomic_store_explicit(&flag, 0, memory_order_release); } return NULL; }

static void run(const char *name, void *(*wf)(void *), int mode) {
    pthread_t t; char b[8] = {0};
    int kq = -1;
    if (mode == 1) { kq = kqueue(); struct kevent ev; EV_SET(&ev, comp[0], EVFILT_READ, EV_ADD | EV_CLEAR, 0, 0, NULL); kevent(kq, &ev, 1, NULL, 0, NULL); fcntl(comp[0], F_SETFL, O_NONBLOCK); }
    double c0 = cpu_us(), t0 = now_us();
    pthread_create(&t, NULL, wf, NULL);
    for (int i = 0; i < N; i++) {
        if (mode == 0) { if (send(sub[1], b, 8, 0) != 8) abort(); if (recv(comp[0], b, 8, 0) != 8) abort(); }
        else if (mode == 1) { if (send(sub[1], b, 8, 0) != 8) abort(); struct kevent ev; kevent(kq, NULL, 0, &ev, 1, NULL); while (recv(comp[0], b, 8, 0) == 8) {} if (errno != EAGAIN) abort(); }
        else if (mode == 2) { pthread_mutex_lock(&mu); turn = 1; pthread_cond_signal(&cv_w); while (turn != 0) pthread_cond_wait(&cv_l, &mu); pthread_mutex_unlock(&mu); }
        else { atomic_store_explicit(&flag, 1, memory_order_release); while (atomic_load_explicit(&flag, memory_order_acquire) != 0) ; }
    }
    pthread_join(t, NULL);
    double t1 = now_us(), c1 = cpu_us();
    printf("%-8s %8.0f rt/s  wall %6.2f us/rt  cpu(both threads) %6.2f us/rt\n", name, N / ((t1 - t0) / 1e6), (t1 - t0) / N, (c1 - c0) / N);
    if (kq >= 0) { close(kq); fcntl(comp[0], F_SETFL, 0); }
}
int main(int argc, char **argv) {
    if (argc > 1) N = atoi(argv[1]);
    if (socketpair(AF_UNIX, SOCK_DGRAM, 0, sub) || socketpair(AF_UNIX, SOCK_DGRAM, 0, comp)) { perror("socketpair"); return 1; }
    run("spin", w_spin, 3);
    run("condvar", w_cond, 2);
    run("dgram", w_dgram, 0);
    run("dgramk", w_dgram, 1);
    return 0;
}
