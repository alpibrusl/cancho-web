// Closed-loop keep-alive load generator, from lex-sys benches/server/kload.c, with
// a method and a body so a POST can be measured:
//
//   kload <port> <threads> <connections-per-thread> <seconds> <path> [lat] [METHOD [BODY]]
//
// `lat` is a literal word (use `-` to skip it). With METHOD POST, BODY is sent as
// `application/json` with its Content-Length.
//
// KLOAD_EXPECT=200 counts every response with another status as wrong and fails the
// run (exit 1) if there was one: a server that answers 500 quickly is not fast.
//
// A response may be up to 64 KiB (a page of 100 users is about 9 KiB); a longer one is a
// "short read" failure, not a miscount.
//
// KLOAD_REQUESTS=N stops after N responses in total instead of after <seconds> (and
// reports requests a second over the time that took): for a workload that adds state
// per request, where "as many as fit in five seconds" would fill the store.
//
// Prints requests a second. With a sixth argument, `lat`, also prints one line
// of latency percentiles in microseconds: from just before a request is written
// to the whole response having been read. Closed loop, K in flight per thread, so
// this is a request's service time *plus the wait behind the others in its
// round* -- the latency a client of a busy server sees, not the latency of an
// idle one.
// Closed-loop keep-alive load: T threads, each owning K connections. A round is
// "send one request on every connection, then read every response", so K
// requests are in flight per thread. Counts completed responses for SECS seconds.
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>
#include <unistd.h>
static int port, secs, K, want_lat; static volatile int stop; static long counts[64]; static const char *path, *method = "GET", *body = ""; static long budget; static int expect; static long wrong[64];
static unsigned *lats[64]; static long nlat[64], caplat[64];
static unsigned long long now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000000000ull + t.tv_nsec; }
static int cmp(const void *a, const void *b) { unsigned x = *(const unsigned*)a, y = *(const unsigned*)b; return x < y ? -1 : x > y; }
static int readresp(int fd, char *buf) {          // one response, by Content-Length; returns bytes or -1
  int have = 0, need = -1, head = -1;
  for (;;) {
    int n = read(fd, buf + have, 65535 - have); if (n <= 0) return -1; have += n; buf[have] = 0;
    if (head < 0) { char *e = strstr(buf, "\r\n\r\n"); if (!e) continue; head = e - buf + 4;
      char *c = strcasestr(buf, "content-length: "); need = head + (c ? atoi(c + 16) : 0); }
    if (have >= need) return have;
  }
}
static void *run(void *a) {
  long id = (long)a; char req[2048];
  if (!strcmp(method, "GET")) snprintf(req, sizeof req, "GET %s HTTP/1.1\r\nHost: x\r\n\r\n", path);
  else snprintf(req, sizeof req, "%s %s HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: %zu\r\n\r\n%s", method, path, strlen(body), body);
  int *fds = malloc(sizeof(int) * K); unsigned long long *sent = malloc(sizeof(unsigned long long) * K); char buf[65536]; struct sockaddr_in sa = {0}; sa.sin_family = AF_INET; sa.sin_port = htons(port); inet_pton(AF_INET, "127.0.0.1", &sa.sin_addr);
  for (int i = 0; i < K; i++) { fds[i] = socket(AF_INET, SOCK_STREAM, 0); int one = 1; setsockopt(fds[i], IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    if (connect(fds[i], (struct sockaddr*)&sa, sizeof sa) < 0) { perror("connect"); exit(1); } }
  while (!stop && (!budget || counts[id] < budget)) {
    for (int i = 0; i < K; i++) { sent[i] = want_lat ? now_ns() : 0; if (write(fds[i], req, strlen(req)) < 0) { perror("write"); return 0; } }
    for (int i = 0; i < K; i++) { if (readresp(fds[i], buf) < 0) { fprintf(stderr, "short read\n"); return 0; } counts[id]++;
      if (expect && atoi(buf + 9) != expect) { if (!wrong[id]) fprintf(stderr, "kload: first wrong response: %.60s\n", buf); wrong[id]++; }
      if (want_lat) { if (nlat[id] == caplat[id]) { caplat[id] = caplat[id] ? caplat[id] * 2 : 1 << 16; lats[id] = realloc(lats[id], caplat[id] * sizeof(unsigned)); }
        unsigned long long d = (now_ns() - sent[i]) / 1000; lats[id][nlat[id]++] = d > 4000000000ull ? 4000000000u : (unsigned)d; } }
  }
  return 0;
}
int main(int c, char **v) {
  port = atoi(v[1]); int threads = atoi(v[2]); K = atoi(v[3]); secs = atoi(v[4]); path = v[5]; want_lat = c > 6 && strcmp(v[6], "-");
  if (c > 7) method = v[7];
  if (c > 8) body = v[8];
  if (getenv("KLOAD_EXPECT")) expect = atoi(getenv("KLOAD_EXPECT"));
  const char *total = getenv("KLOAD_REQUESTS"); if (total) budget = atol(total) / threads;
  pthread_t t[64]; unsigned long long t0 = now_ns(); for (long i = 0; i < threads; i++) pthread_create(&t[i], 0, run, (void*)i);
  if (!budget) { sleep(secs); stop = 1; }
  long sum = 0; for (int i = 0; i < threads; i++) { pthread_join(t[i], 0); sum += counts[i]; }
  double elapsed = budget ? (now_ns() - t0) / 1e9 : secs;
  long bad = 0; for (int i = 0; i < threads; i++) bad += wrong[i];
  if (bad) { fprintf(stderr, "kload: %ld of %ld responses were not %d\n", bad, sum, expect); printf("%ld\n", (long)(sum / elapsed)); return 1; }
  printf("%ld\n", (long)(sum / elapsed));
  if (want_lat) { long n = 0; for (int i = 0; i < threads; i++) n += nlat[i];
    unsigned *all = malloc(n * sizeof(unsigned)); long at = 0; for (int i = 0; i < threads; i++) { memcpy(all + at, lats[i], nlat[i] * sizeof(unsigned)); at += nlat[i]; }
    qsort(all, n, sizeof(unsigned), cmp);
    printf("p50 %u p90 %u p99 %u p99.9 %u max %u us (%ld samples)\n", all[n / 2], all[n * 9 / 10], all[n * 99 / 100], all[n * 999 / 1000], all[n - 1], n); }
  return 0;
}
