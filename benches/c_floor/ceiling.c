// The ceiling: what one core can do for HTTP over loopback TCP when the server does
// no work at all. One epoll loop; every read gets the same canned 200 back, whatever
// it was (no parsing, no routing, no state). It is not a correct HTTP server -- it
// would answer a half-received request -- and is only meant to be loaded by a client
// that sends one whole request at a time, as benches/kload.c does.
//
//   cc -O2 -o ceiling ceiling.c && ./ceiling 8000
//
// Its figure is what the kernel's socket path allows (epoll_wait, read, send): the
// number no server on this machine, in any language, can beat by doing less.
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <unistd.h>

int main(int argc, char **argv) {
  static const char reply[] = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n{\"ok\":true}";
  int ls = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0), one = 1;
  setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  struct sockaddr_in sa = {0};
  sa.sin_family = AF_INET;
  sa.sin_port = htons(argc > 1 ? atoi(argv[1]) : 8000);
  inet_pton(AF_INET, "127.0.0.1", &sa.sin_addr);
  if (bind(ls, (struct sockaddr *)&sa, sizeof sa) || listen(ls, 1024)) { perror("listen"); return 1; }
  int ep = epoll_create1(0);
  struct epoll_event ev = {.events = EPOLLIN, .data.fd = ls};
  epoll_ctl(ep, EPOLL_CTL_ADD, ls, &ev);
  printf("listening\n");
  fflush(stdout);
  struct epoll_event evs[256];
  char buf[65536];
  for (;;) {
    int n = epoll_wait(ep, evs, 256, -1);
    for (int i = 0; i < n; i++) {
      if (evs[i].data.fd == ls) {
        int fd;
        while ((fd = accept4(ls, NULL, NULL, SOCK_NONBLOCK)) >= 0) {
          setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
          struct epoll_event ce = {.events = EPOLLIN, .data.fd = fd};
          epoll_ctl(ep, EPOLL_CTL_ADD, fd, &ce);
        }
        continue;
      }
      ssize_t r = read(evs[i].data.fd, buf, sizeof buf);
      if (r <= 0) { close(evs[i].data.fd); continue; }
      send(evs[i].data.fd, reply, sizeof reply - 1, MSG_NOSIGNAL);
    }
  }
}
