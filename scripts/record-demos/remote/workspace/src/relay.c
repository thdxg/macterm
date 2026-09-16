#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/epoll.h>
#include <sys/socket.h>

#include "relay.h"

struct relay {
	int subscribers[MAX_SUBSCRIBERS];
	size_t count;
};

struct relay *relay_new(void) {
	struct relay *r = calloc(1, sizeof *r);
	for (size_t i = 0; i < MAX_SUBSCRIBERS; i++) r->subscribers[i] = -1;
	return r;
}

void relay_accept(struct relay *r, int ep, int srv) {
	int fd = accept4(srv, NULL, NULL, SOCK_NONBLOCK);
	if (fd < 0) return;
	if (r->count == MAX_SUBSCRIBERS) { close(fd); return; }

	r->subscribers[r->count++] = fd;
	struct epoll_event ev = { .events = EPOLLIN | EPOLLRDHUP, .data.fd = fd };
	epoll_ctl(ep, EPOLL_CTL_ADD, fd, &ev);
}

/* One read, many writes. A subscriber that cannot keep up is dropped rather
   than allowed to stall the upstream — backpressure belongs to the slow peer. */
void relay_pump(struct relay *r, int ep, int fd) {
	char buf[16384];
	ssize_t n = read(fd, buf, sizeof buf);
	if (n <= 0) { relay_drop(r, ep, fd); return; }

	for (size_t i = 0; i < r->count; i++) {
		int out = r->subscribers[i];
		if (out < 0 || out == fd) continue;
		if (send(out, buf, (size_t)n, MSG_DONTWAIT | MSG_NOSIGNAL) != n)
			relay_drop(r, ep, out);
	}
}

void relay_drop(struct relay *r, int ep, int fd) {
	epoll_ctl(ep, EPOLL_CTL_DEL, fd, NULL);
	close(fd);
	for (size_t i = 0; i < r->count; i++)
		if (r->subscribers[i] == fd) r->subscribers[i] = -1;
}
