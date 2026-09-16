# edge-relay

A small TCP relay that fans one upstream connection out to many subscribers.
Built for the demo box: `make && ./edge-relay --port 8080`.

- `src/server.c`  accept loop, epoll, backpressure
- `src/relay.c`   the fan-out itself
- `Makefile`      one target, no configure step
