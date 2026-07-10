#ifndef ENGINEOS_MUX_CLIENT_H
#define ENGINEOS_MUX_CLIENT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

struct engineos_mux_client {
	int fd;
	uint64_t revision;
	char *socket_path;
	bool ready;
};

bool engineos_mux_client_connect(struct engineos_mux_client *client,
	const char *socket_path, char *error, size_t error_size);
void engineos_mux_client_destroy(struct engineos_mux_client *client);

#endif
