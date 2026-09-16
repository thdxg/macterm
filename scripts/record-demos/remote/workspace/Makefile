CFLAGS := -O2 -Wall -Wextra -std=c11
edge-relay: src/server.c src/relay.c
	$(CC) $(CFLAGS) -o $@ $^
clean:
	rm -f edge-relay
