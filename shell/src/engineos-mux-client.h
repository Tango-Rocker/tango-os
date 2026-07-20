#ifndef ENGINEOS_MUX_CLIENT_H
#define ENGINEOS_MUX_CLIENT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "engine-mux-protocol.h"

struct engineos_mux_ui_span {
	uint32_t start;
	uint32_t end;
	uint16_t attributes;
	int32_t foreground;
	int32_t background;
	int32_t underline_colour;
};

struct engineos_mux_ui_row {
	char *text;
	struct engineos_mux_ui_span *spans;
	size_t span_count;
};

struct engineos_mux_ui_model {
	uint32_t view_id;
	uint32_t columns;
	uint32_t rows;
	int32_t status_y;
	struct engineos_mux_ui_row *status_rows;
	size_t status_row_count;
	uint32_t menu_x;
	uint32_t menu_y;
	uint32_t menu_width;
	uint32_t menu_height;
	struct engineos_mux_ui_row *menu_rows;
	size_t menu_row_count;
	char mode[16];
	bool prompt_active;
	bool message_active;
	bool menu_active;
	bool changed;
	bool invalidated;
	bool ready;
};

struct engineos_mux_damage_cell {
	uint32_t x;
	uint32_t y;
};

struct engineos_mux_grid_model {
	uint64_t revision;
	uint32_t columns;
	uint32_t rows;
	uint32_t cursor_x;
	uint32_t cursor_y;
	uint32_t nonblank_cells;
	uint16_t flags;
	struct engine_mux_grid_cell *cells;
	struct engineos_mux_damage_cell *damage_cells;
	size_t damage_count;
	bool full_damage;
	bool ready;
	bool subscribed;
	bool damage_pending;
};

struct engineos_mux_pane_model {
	uint32_t pane_id;
	uint32_t generation;
	uint32_t left;
	uint32_t top;
	uint32_t columns;
	uint32_t rows;
	bool active;
	bool visible;
	bool window_active;
	char presentation[16];
	char view_mode[16];
	bool presentation_mapped;
	uint32_t surface_tabs;
	uint32_t active_surface_id;
	uint32_t lease_client_id;
	uint32_t lease_view_id;
	uint32_t image_id;
	uint32_t image_bytes;
	uint32_t image_lease_client_id;
	uint32_t image_lease_view_id;
	char image_mime[16];
	char *image_owner;
	struct engineos_mux_grid_model grid;
};

struct engineos_mux_presentation_target {
	uint32_t pane_id;
	uint32_t generation;
	char presentation[16];
	char view_mode[16];
};

struct engineos_mux_view_snapshot {
	uint64_t revision;
	uint32_t client_id;
	uint32_t view_id;
	uint32_t pane_id;
	uint32_t pane_generation;
	char *output;
	char *session_id;
	struct engineos_mux_pane_model *panes;
	size_t pane_count;
	struct engineos_mux_ui_model ui;
	bool ready;
};

struct engineos_mux_client {
	int fd;
	uint64_t revision;
	uint64_t grid_revision;
	uint32_t pane_id;
	uint32_t pane_generation;
	char pane_presentation[16];
	char pane_view_mode[16];
	char prefix[32];
	char prefix2[32];
	bool pane_presentation_mapped;
	uint32_t pane_surface_tabs;
	uint32_t pane_active_surface_id;
	uint32_t pane_lease_client_id;
	uint32_t pane_lease_view_id;
	struct engineos_mux_pane_model *panes;
	size_t pane_count;
	char *session_id;
	uint32_t frontend_client_id;
	uint32_t primary_view_id;
	uint32_t grid_columns;
	uint32_t grid_rows;
	uint32_t grid_cursor_x;
	uint32_t grid_cursor_y;
	uint32_t grid_nonblank_cells;
	uint16_t grid_flags;
	struct engine_mux_grid_cell *grid_cells;
	struct engineos_mux_damage_cell *grid_damage_cells;
	size_t grid_damage_count;
	bool grid_full_damage;
	bool selected_grid_damage_pending;
	bool ui_changed;
	uint32_t ui_columns;
	uint32_t ui_rows;
	int32_t ui_status_y;
	struct engineos_mux_ui_row *ui_status_rows;
	size_t ui_status_row_count;
	uint32_t ui_menu_x;
	uint32_t ui_menu_y;
	uint32_t ui_menu_width;
	uint32_t ui_menu_height;
	struct engineos_mux_ui_row *ui_menu_rows;
	size_t ui_menu_row_count;
	char ui_mode[16];
	bool ui_prompt_active;
	bool ui_message_active;
	bool ui_menu_active;
	char *socket_path;
	struct engineos_mux_view_snapshot **view_snapshots;
	size_t view_snapshot_count;
	uint64_t ui_invalidation_count;
	uint32_t last_ui_invalidated_view_id;
	bool state_invalidated_pending;
	bool last_request_rejected;
	bool last_image_resync_required;
	bool ready;
};

bool engineos_mux_client_connect(struct engineos_mux_client *client,
	const char *socket_path, char *error, size_t error_size);
bool engineos_mux_client_handle_event(struct engineos_mux_client *client,
	bool *grid_changed, bool *state_changed, char *error, size_t error_size);
bool engineos_mux_client_refresh_presentation(struct engineos_mux_client *client,
	char *error, size_t error_size);
bool engineos_mux_client_request_view_snapshot(
	struct engineos_mux_client *client, uint32_t view_id,
	struct engineos_mux_view_snapshot *snapshot, bool *grid_changed,
	char *error, size_t error_size);
struct engineos_mux_pane_model *engineos_mux_client_view_pane_grid(
	struct engineos_mux_client *client,
	const struct engineos_mux_pane_model *pane);
bool engineos_mux_client_send_input(struct engineos_mux_client *client,
	const void *bytes, size_t length, bool *grid_changed,
	char *error, size_t error_size);
bool engineos_mux_client_register_view(struct engineos_mux_client *client,
	uint32_t view_id, const char *output, uint32_t columns, uint32_t rows,
	uint32_t pixel_width, uint32_t pixel_height, uint32_t scale_milli, bool focused,
	bool *grid_changed, char *error, size_t error_size);
bool engineos_mux_client_unregister_view(struct engineos_mux_client *client,
	uint32_t view_id, bool *grid_changed, char *error, size_t error_size);
bool engineos_mux_client_focus_view(struct engineos_mux_client *client,
	uint32_t view_id, bool *grid_changed, char *error, size_t error_size);
bool engineos_mux_client_send_key(struct engineos_mux_client *client,
	uint32_t view_id, uint32_t pane_id, uint32_t generation,
	const char *key_name, bool *grid_changed,
	char *error, size_t error_size);
bool engineos_mux_client_send_mouse(struct engineos_mux_client *client,
	uint32_t view_id, uint32_t x, uint32_t y, const char *event,
	const char *button, uint32_t modifiers, bool *grid_changed,
	char *error, size_t error_size);
bool engineos_mux_client_request_image(struct engineos_mux_client *client,
	uint32_t pane_id, uint32_t generation, uint32_t image_id,
	uint32_t expected_bytes, uint8_t **data, size_t *size,
	char *error, size_t error_size);
bool engineos_mux_client_request_ui(struct engineos_mux_client *client,
	uint32_t view_id, bool *grid_changed, char *error, size_t error_size);
bool engineos_mux_client_request_view_ui(struct engineos_mux_client *client,
	uint32_t view_id, struct engineos_mux_view_snapshot *snapshot,
	bool *grid_changed, char *error, size_t error_size);
bool engineos_mux_client_resolve_presentation(struct engineos_mux_client *client,
	int32_t pid, struct engineos_mux_presentation_target *target,
	bool *grid_changed, char *error, size_t error_size);
bool engineos_mux_client_map_presentation(struct engineos_mux_client *client,
	const struct engineos_mux_presentation_target *target, int32_t pid,
	uint32_t surface_id, uint32_t view_id, const char *role, bool *grid_changed,
	char *error, size_t error_size);
bool engineos_mux_client_unmap_presentation(struct engineos_mux_client *client,
	uint32_t pane_id, uint32_t generation, int32_t pid, uint32_t surface_id,
	bool *grid_changed, char *error, size_t error_size);
void engineos_mux_client_clear_render_damage(struct engineos_mux_client *client);
void engineos_mux_pane_model_clear_render_damage(
	struct engineos_mux_pane_model *pane);
void engineos_mux_view_snapshot_destroy(
	struct engineos_mux_view_snapshot *snapshot);
void engineos_mux_client_release_view_snapshot(
	struct engineos_mux_client *client,
	struct engineos_mux_view_snapshot *snapshot);
void engineos_mux_client_destroy(struct engineos_mux_client *client);

#endif
