#ifndef ENGINEOS_MUX_CLIENT_H
#define ENGINEOS_MUX_CLIENT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "engine-mux-protocol.h"

struct engineos_mux_client {
	int fd;
	uint64_t revision;
	uint64_t grid_revision;
	uint32_t pane_id;
	uint32_t pane_generation;
	uint32_t grid_columns;
	uint32_t grid_rows;
	uint32_t grid_cursor_x;
	uint32_t grid_cursor_y;
	uint32_t grid_nonblank_cells;
	struct engine_mux_grid_cell *grid_cells;
	char *socket_path;
	bool ready;
};

bool engineos_mux_client_connect(struct engineos_mux_client *client,
	const char *socket_path, char *error, size_t error_size);
bool engineos_mux_client_handle_event(struct engineos_mux_client *client,
	bool *grid_changed, char *error, size_t error_size);
void engineos_mux_client_destroy(struct engineos_mux_client *client);

#endif
