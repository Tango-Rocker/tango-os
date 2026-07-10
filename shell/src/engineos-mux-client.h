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
	char *session_id;
	uint32_t primary_view_id;
	uint32_t grid_columns;
	uint32_t grid_rows;
	uint32_t grid_cursor_x;
	uint32_t grid_cursor_y;
	uint32_t grid_nonblank_cells;
	uint16_t grid_flags;
	struct engine_mux_grid_cell *grid_cells;
	char *socket_path;
	bool ready;
};

bool engineos_mux_client_connect(struct engineos_mux_client *client,
	const char *socket_path, char *error, size_t error_size);
bool engineos_mux_client_handle_event(struct engineos_mux_client *client,
	bool *grid_changed, char *error, size_t error_size);
bool engineos_mux_client_send_input(struct engineos_mux_client *client,
	const void *bytes, size_t length, bool *grid_changed,
	char *error, size_t error_size);
bool engineos_mux_client_register_view(struct engineos_mux_client *client,
	uint32_t view_id, const char *output, uint32_t pixel_width,
	uint32_t pixel_height, uint32_t scale_milli, bool focused,
	bool *grid_changed, char *error, size_t error_size);
bool engineos_mux_client_unregister_view(struct engineos_mux_client *client,
	uint32_t view_id, bool *grid_changed, char *error, size_t error_size);
bool engineos_mux_client_send_key(struct engineos_mux_client *client,
	uint32_t view_id, const char *key_name, bool *grid_changed,
	char *error, size_t error_size);
void engineos_mux_client_destroy(struct engineos_mux_client *client);

#endif
