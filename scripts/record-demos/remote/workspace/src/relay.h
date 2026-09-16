#ifndef RELAY_H
#define RELAY_H

#include <stddef.h>

#define MAX_SUBSCRIBERS 256

struct relay;

struct relay *relay_new(void);
void relay_accept(struct relay *r, int ep, int srv);
void relay_pump(struct relay *r, int ep, int fd);
void relay_drop(struct relay *r, int ep, int fd);

#endif
