#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <netinet/in.h>

#include "relay.h"

#define MAX_EVENTS 64

static int listen_on(unsigned short port) {
	int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
	if (fd < 0) return -1;

	int yes = 1;
	setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof yes);

	struct sockaddr_in addr = {
		.sin_family = AF_INET,
		.sin_addr.s_addr = htonl(INADDR_ANY),
		.sin_port = htons(port),
	};
	if (bind(fd, (struct sockaddr *)&addr, sizeof addr) < 0) goto fail;
	if (listen(fd, SOMAXCONN) < 0) goto fail;
	return fd;

fail:
	close(fd);
	return -1;
}

int main(int argc, char **argv) {
	unsigned short port = 8080;
	if (argc == 3 && strcmp(argv[1], "--port") == 0)
		port = (unsigned short)atoi(argv[2]);

	int srv = listen_on(port);
	if (srv < 0) {
		fprintf(stderr, "listen: %s\n", strerror(errno));
		return 1;
	}

	struct relay *r = relay_new();
	int ep = epoll_create1(0);
	struct epoll_event ev = { .events = EPOLLIN, .data.fd = srv };
	epoll_ctl(ep, EPOLL_CTL_ADD, srv, &ev);

	fprintf(stderr, "edge-relay listening on :%u\n", port);

	struct epoll_event events[MAX_EVENTS];
	for (;;) {
		int n = epoll_wait(ep, events, MAX_EVENTS, -1);
		if (n < 0 && errno == EINTR) continue;
		for (int i = 0; i < n; i++) {
			if (events[i].data.fd == srv)
				relay_accept(r, ep, srv);
			else
				relay_pump(r, ep, events[i].data.fd);
		}
	}
}
