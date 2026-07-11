#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L

#include "engineos-mux-client.h"
#include "engine-mux-protocol.h"

#include <arpa/inet.h>
#include <errno.h>
#include <json-c/json.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

static bool exchange_json_request(struct engineos_mux_client *client,
	uint16_t request_type, uint16_t expected_type, const char *payload,
	const char *expected_schema, struct json_object **response,
	bool *grid_changed, char *error, size_t error_size);
static bool service_pending_grid_damage(struct engineos_mux_client *client,
	bool *grid_changed, char *error, size_t error_size);
static bool json_u32(struct json_object *parent, const char *name,
	uint32_t maximum, uint32_t *value);

static uint64_t host_to_be64(uint64_t value) {
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
	return ((uint64_t)htonl((uint32_t)(value >> 32))) |
		((uint64_t)htonl((uint32_t)value) << 32);
#else
	return value;
#endif
}

static uint64_t be64_to_host(uint64_t value) {
	return host_to_be64(value);
}

static void update_nonblank_count(struct engineos_mux_client *client) {
	uint32_t cell_count = client->grid_columns * client->grid_rows;
	uint32_t nonblank = 0;
	for (uint32_t index = 0; index < cell_count; index++) {
		const struct engine_mux_grid_cell *cell = &client->grid_cells[index];
		if ((cell->flags & ENGINE_MUX_GRID_CELL_PADDING) == 0 &&
				cell->text_length != 0 &&
				!(cell->text_length == 1 &&
				  (cell->text[0] == 0 || cell->text[0] == ' '))) {
			nonblank++;
		}
	}
	client->grid_nonblank_cells = nonblank;
}

static uint32_t grid_nonblank_count(const struct engine_mux_grid_cell *cells,
		uint32_t columns, uint32_t rows) {
	uint32_t nonblank = 0;
	for (uint32_t index = 0; index < columns * rows; index++) {
		const struct engine_mux_grid_cell *cell = &cells[index];
		if ((cell->flags & ENGINE_MUX_GRID_CELL_PADDING) == 0 &&
				cell->text_length != 0 &&
				!(cell->text_length == 1 &&
				  (cell->text[0] == 0 || cell->text[0] == ' ')))
			nonblank++;
	}
	return nonblank;
}

static void free_grid_model(struct engineos_mux_grid_model *grid) {
	free(grid->cells);
	free(grid->damage_cells);
	memset(grid, 0, sizeof(*grid));
}

static bool clone_grid_model(const struct engineos_mux_grid_model *source,
		struct engineos_mux_grid_model *destination) {
	struct engineos_mux_grid_model clone = *source;
	clone.cells = NULL;
	clone.damage_cells = NULL;
	size_t cell_count = (size_t)source->columns * source->rows;
	if (cell_count != 0) {
		clone.cells = malloc(cell_count * sizeof(*clone.cells));
		if (clone.cells == NULL)
			return false;
		memcpy(clone.cells, source->cells,
			cell_count * sizeof(*clone.cells));
	}
	if (source->damage_count != 0) {
		clone.damage_cells = malloc(source->damage_count *
			sizeof(*clone.damage_cells));
		if (clone.damage_cells == NULL) {
			free(clone.cells);
			return false;
		}
		memcpy(clone.damage_cells, source->damage_cells,
			source->damage_count * sizeof(*clone.damage_cells));
	}
	free_grid_model(destination);
	*destination = clone;
	return true;
}

static void free_pane_models(struct engineos_mux_pane_model *panes,
		size_t count) {
	for (size_t index = 0; index < count; index++)
		free_grid_model(&panes[index].grid);
	free(panes);
}

static struct engineos_mux_pane_model *find_pane_model(
		struct engineos_mux_client *client, uint32_t pane_id,
		uint32_t generation) {
	for (size_t index = 0; index < client->pane_count; index++) {
		if (client->panes[index].pane_id == pane_id &&
				client->panes[index].generation == generation)
			return &client->panes[index];
	}
	for (size_t view = 0; view < client->view_snapshot_count; view++) {
		struct engineos_mux_view_snapshot *snapshot =
			client->view_snapshots[view];
		for (size_t index = 0; snapshot != NULL &&
				index < snapshot->pane_count; index++) {
			if (snapshot->panes[index].pane_id == pane_id &&
					snapshot->panes[index].generation == generation &&
					snapshot->panes[index].grid.ready)
				return &snapshot->panes[index];
		}
	}
	return NULL;
}

static bool track_view_snapshot(struct engineos_mux_client *client,
		struct engineos_mux_view_snapshot *snapshot, char *error,
		size_t error_size) {
	for (size_t index = 0; index < client->view_snapshot_count; index++) {
		if (client->view_snapshots[index] == snapshot)
			return true;
	}
	struct engineos_mux_view_snapshot **tracked = realloc(
		client->view_snapshots, (client->view_snapshot_count + 1) *
		sizeof(*tracked));
	if (tracked == NULL) {
		snprintf(error, error_size, "out of memory tracking view snapshot");
		return false;
	}
	client->view_snapshots = tracked;
	client->view_snapshots[client->view_snapshot_count++] = snapshot;
	return true;
}

static bool mark_grid_invalidation(struct engineos_mux_client *client,
		uint32_t pane_id, uint32_t generation, char *error,
		size_t error_size) {
	if (pane_id == client->pane_id && generation == client->pane_generation) {
		client->selected_grid_damage_pending = true;
		return true;
	}
	struct engineos_mux_pane_model *pane = find_pane_model(client, pane_id,
		generation);
	if (pane == NULL || !pane->grid.ready || !pane->grid.subscribed) {
		snprintf(error, error_size,
			"grid invalidation has no retained pane model");
		return false;
	}
	pane->grid.damage_pending = true;
	return true;
}

static bool exchange(int fd, uint16_t request_type, uint64_t request_id,
		uint16_t expected_type, uint64_t *revision, const char *payload,
		struct json_object **response, char *error, size_t error_size) {
	size_t payload_length = strlen(payload);
	struct engine_mux_frame_header header = {
		.magic = htonl(ENGINE_MUX_MAGIC),
		.version = htons(ENGINE_MUX_PROTOCOL_VERSION),
		.type = htons(request_type),
		.request_id = host_to_be64(request_id),
		.state_revision = host_to_be64(*revision),
		.payload_length = htonl((uint32_t)payload_length),
	};
	struct iovec parts[] = {
		{.iov_base = &header, .iov_len = sizeof(header)},
		{.iov_base = (char *)payload, .iov_len = payload_length},
	};
	struct msghdr message = {.msg_iov = parts, .msg_iovlen = 2};
	if (sendmsg(fd, &message, MSG_NOSIGNAL) < 0) {
		snprintf(error, error_size, "send: %s", strerror(errno));
		return false;
	}
	unsigned char packet[sizeof(header) + ENGINE_MUX_MAX_PAYLOAD + 1];
	ssize_t count = recv(fd, packet, sizeof(packet), 0);
	if (count < (ssize_t)sizeof(header)) {
		snprintf(error, error_size, "truncated response");
		return false;
	}
	memcpy(&header, packet, sizeof(header));
	uint32_t length = ntohl(header.payload_length);
	uint16_t response_type = ntohs(header.type);
	if (ntohl(header.magic) != ENGINE_MUX_MAGIC ||
			ntohs(header.version) != ENGINE_MUX_PROTOCOL_VERSION ||
			length > ENGINE_MUX_MAX_PAYLOAD || sizeof(header) + length != (size_t)count) {
		snprintf(error, error_size, "invalid response frame");
		return false;
	}
	char *json_text = malloc((size_t)length + 1);
	if (json_text == NULL) {
		snprintf(error, error_size, "out of memory");
		return false;
	}
	memcpy(json_text, packet + sizeof(header), length);
	json_text[length] = '\0';
	struct json_object *root = json_tokener_parse(json_text);
	free(json_text);
	if (root == NULL) {
		snprintf(error, error_size, "response payload is not JSON");
		return false;
	}
	if (response_type == ENGINE_MUX_ERROR) {
		struct json_object *message_object = NULL;
		const char *server_message = "mux server rejected request";
		if (json_object_object_get_ex(root, "message", &message_object)) {
			server_message = json_object_get_string(message_object);
		}
		snprintf(error, error_size, "%s", server_message);
		json_object_put(root);
		return false;
	}
	if (response_type != expected_type) {
		snprintf(error, error_size, "unexpected response type %u", response_type);
		json_object_put(root);
		return false;
	}
	if (expected_type == ENGINE_MUX_SNAPSHOT) {
		struct json_object *schema = NULL;
		struct json_object *panes = NULL;
		if (!json_object_object_get_ex(root, "schema", &schema) ||
				strcmp(json_object_get_string(schema), "engine-mux/snapshot-v1") != 0 ||
				!json_object_object_get_ex(root, "panes", &panes) ||
				!json_object_is_type(panes, json_type_array)) {
			snprintf(error, error_size, "snapshot contract is invalid");
			json_object_put(root);
			return false;
		}
	}
	*revision = be64_to_host(header.state_revision);
	if (response != NULL) {
		*response = root;
	} else {
		json_object_put(root);
	}
	return true;
}

static bool parse_pane_presentation(struct engineos_mux_client *client,
		struct json_object *pane, char *error, size_t error_size) {
	struct json_object *presentation = NULL, *view_mode = NULL;
	struct json_object *mapped = NULL, *surface_tabs = NULL;
	struct json_object *active_surface_id = NULL;
	struct json_object *lease_client_id = NULL, *lease_view_id = NULL;
	if (!json_object_object_get_ex(pane, "presentation", &presentation) ||
			!json_object_is_type(presentation, json_type_string) ||
			!json_object_object_get_ex(pane, "view_mode", &view_mode) ||
			!json_object_is_type(view_mode, json_type_string) ||
			!json_object_object_get_ex(pane, "mapped", &mapped) ||
			!json_object_is_type(mapped, json_type_boolean) ||
			!json_object_object_get_ex(pane, "surface_tabs", &surface_tabs) ||
			!json_object_is_type(surface_tabs, json_type_int) ||
			!json_object_object_get_ex(pane, "active_surface_id",
				&active_surface_id) ||
			!json_object_is_type(active_surface_id, json_type_int) ||
			!json_object_object_get_ex(pane, "lease_client_id",
				&lease_client_id) ||
			!json_object_is_type(lease_client_id, json_type_int) ||
			!json_object_object_get_ex(pane, "lease_view_id", &lease_view_id) ||
			!json_object_is_type(lease_view_id, json_type_int)) {
		snprintf(error, error_size, "snapshot presentation contract is invalid");
		return false;
	}
	const char *presentation_text = json_object_get_string(presentation);
	const char *view_mode_text = json_object_get_string(view_mode);
	int64_t tabs = json_object_get_int64(surface_tabs);
	int64_t active_id = json_object_get_int64(active_surface_id);
	int64_t lease_client = json_object_get_int64(lease_client_id);
	int64_t lease_view = json_object_get_int64(lease_view_id);
	bool is_mapped = json_object_get_boolean(mapped);
	if (strlen(presentation_text) >= sizeof(client->pane_presentation) ||
			strlen(view_mode_text) >= sizeof(client->pane_view_mode) ||
			tabs < 0 || tabs > UINT32_MAX ||
			active_id < 0 || active_id > UINT32_MAX ||
			lease_client < 0 || lease_client > UINT32_MAX ||
			lease_view < 0 || lease_view > UINT32_MAX ||
			(tabs == 0 && active_id != 0) || (tabs > 0 && active_id == 0) ||
			(is_mapped && (lease_client == 0 || lease_view == 0)) ||
			(!is_mapped && (lease_client != 0 || lease_view != 0))) {
		snprintf(error, error_size, "snapshot presentation state is invalid");
		return false;
	}
	strcpy(client->pane_presentation, presentation_text);
	strcpy(client->pane_view_mode, view_mode_text);
	client->pane_presentation_mapped = is_mapped;
	client->pane_surface_tabs = (uint32_t)tabs;
	client->pane_active_surface_id = (uint32_t)active_id;
	client->pane_lease_client_id = (uint32_t)lease_client;
	client->pane_lease_view_id = (uint32_t)lease_view;
	return true;
}

static bool parse_pane_prefixes(struct engineos_mux_client *client,
		struct json_object *pane, char *error, size_t error_size) {
	struct json_object *prefix = NULL, *prefix2 = NULL;
	if (!json_object_object_get_ex(pane, "prefix", &prefix) ||
			!json_object_is_type(prefix, json_type_string) ||
			!json_object_object_get_ex(pane, "prefix2", &prefix2) ||
			!json_object_is_type(prefix2, json_type_string)) {
		snprintf(error, error_size, "snapshot prefix contract is invalid");
		return false;
	}
	const char *first = json_object_get_string(prefix);
	const char *second = json_object_get_string(prefix2);
	if (strlen(first) >= sizeof(client->prefix) ||
			strlen(second) >= sizeof(client->prefix2)) {
		snprintf(error, error_size, "snapshot prefix key is too long");
		return false;
	}
	strcpy(client->prefix, first);
	strcpy(client->prefix2, second);
	return true;
}

static bool parse_pane_models(struct engineos_mux_client *client,
		struct json_object *snapshot, char *error, size_t error_size) {
	struct json_object *panes = NULL;
	uint32_t focused_client_id = 0, focused_view_id = 0;
	if (!json_u32(snapshot, "focused_client_id", UINT32_MAX,
			&focused_client_id) ||
			!json_u32(snapshot, "focused_view_id", UINT32_MAX,
				&focused_view_id) ||
			((focused_client_id == 0) != (focused_view_id == 0))) {
		snprintf(error, error_size, "snapshot focused view identity is invalid");
		return false;
	}
	if (client->frontend_client_id != 0) {
		client->primary_view_id = focused_client_id ==
			client->frontend_client_id ? focused_view_id : 0;
	}
	if (!json_object_object_get_ex(snapshot, "panes", &panes) ||
			!json_object_is_type(panes, json_type_array)) {
		snprintf(error, error_size, "snapshot pane list is invalid");
		return false;
	}
	size_t count = json_object_array_length(panes);
	if (count == 0 || count > UINT32_MAX) {
		snprintf(error, error_size, "snapshot pane count is invalid");
		return false;
	}
	struct engineos_mux_pane_model *models = calloc(count, sizeof(*models));
	if (models == NULL) {
		snprintf(error, error_size, "out of memory");
		return false;
	}
	for (size_t index = 0; index < count; index++) {
		struct json_object *pane = json_object_array_get_idx(panes, index);
		struct json_object *id = NULL, *generation = NULL, *left = NULL;
		struct json_object *top = NULL, *columns = NULL, *rows = NULL;
		struct json_object *active = NULL, *visible = NULL;
		struct json_object *window_active = NULL;
		struct json_object *presentation = NULL, *view_mode = NULL;
		struct json_object *mapped = NULL, *tabs = NULL, *active_surface = NULL;
		struct json_object *lease_client = NULL, *lease_view = NULL;
		if (!json_object_is_type(pane, json_type_object) ||
				!json_object_object_get_ex(pane, "pane_id", &id) ||
				!json_object_object_get_ex(pane, "generation", &generation) ||
				!json_object_object_get_ex(pane, "left", &left) ||
				!json_object_object_get_ex(pane, "top", &top) ||
				!json_object_object_get_ex(pane, "columns", &columns) ||
				!json_object_object_get_ex(pane, "rows", &rows) ||
				!json_object_object_get_ex(pane, "active", &active) ||
				!json_object_object_get_ex(pane, "visible", &visible) ||
				!json_object_object_get_ex(pane, "window_active", &window_active) ||
				!json_object_object_get_ex(pane, "presentation", &presentation) ||
				!json_object_object_get_ex(pane, "view_mode", &view_mode) ||
				!json_object_object_get_ex(pane, "mapped", &mapped) ||
				!json_object_object_get_ex(pane, "surface_tabs", &tabs) ||
				!json_object_object_get_ex(pane, "active_surface_id", &active_surface) ||
				!json_object_object_get_ex(pane, "lease_client_id", &lease_client) ||
				!json_object_object_get_ex(pane, "lease_view_id", &lease_view)) {
			free(models);
			snprintf(error, error_size, "snapshot pane model is incomplete");
			return false;
		}
		if (!json_object_is_type(id, json_type_string) ||
				!json_object_is_type(generation, json_type_int) ||
				!json_object_is_type(left, json_type_int) ||
				!json_object_is_type(top, json_type_int) ||
				!json_object_is_type(columns, json_type_int) ||
				!json_object_is_type(rows, json_type_int) ||
				!json_object_is_type(active, json_type_boolean) ||
				!json_object_is_type(visible, json_type_boolean) ||
				!json_object_is_type(window_active, json_type_boolean) ||
				!json_object_is_type(presentation, json_type_string) ||
				!json_object_is_type(view_mode, json_type_string) ||
				!json_object_is_type(mapped, json_type_boolean) ||
				!json_object_is_type(tabs, json_type_int) ||
				!json_object_is_type(active_surface, json_type_int) ||
				!json_object_is_type(lease_client, json_type_int) ||
				!json_object_is_type(lease_view, json_type_int)) {
			free(models);
			snprintf(error, error_size, "snapshot pane model types are invalid");
			return false;
		}
		const char *id_text = json_object_get_string(id);
		if (id_text != NULL && id_text[0] == '%') id_text++;
		char *end = NULL;
		unsigned long parsed_id = id_text == NULL ? 0 : strtoul(id_text, &end, 10);
		int64_t parsed_generation = json_object_get_int64(generation);
		int64_t parsed_left = json_object_get_int64(left);
		int64_t parsed_top = json_object_get_int64(top);
		int64_t parsed_columns = json_object_get_int64(columns);
		int64_t parsed_rows = json_object_get_int64(rows);
		int64_t parsed_tabs = json_object_get_int64(tabs);
		int64_t parsed_active_surface = json_object_get_int64(active_surface);
		int64_t parsed_lease_client = json_object_get_int64(lease_client);
		int64_t parsed_lease_view = json_object_get_int64(lease_view);
		bool parsed_mapped = json_object_get_boolean(mapped);
		const char *presentation_text = json_object_get_string(presentation);
		const char *view_mode_text = json_object_get_string(view_mode);
		if (id_text == NULL || *id_text == '\0' || *end != '\0' ||
				parsed_id > UINT32_MAX ||
				parsed_generation <= 0 || parsed_generation > UINT32_MAX ||
				parsed_left < 0 || parsed_left > UINT32_MAX ||
				parsed_top < 0 || parsed_top > UINT32_MAX ||
				parsed_columns <= 0 || parsed_columns > UINT32_MAX ||
				parsed_rows <= 0 || parsed_rows > UINT32_MAX ||
				parsed_tabs < 0 || parsed_tabs > UINT32_MAX ||
				parsed_active_surface < 0 || parsed_active_surface > UINT32_MAX ||
				parsed_lease_client < 0 || parsed_lease_client > UINT32_MAX ||
				parsed_lease_view < 0 || parsed_lease_view > UINT32_MAX ||
				(parsed_tabs == 0 && parsed_active_surface != 0) ||
				(parsed_tabs > 0 && parsed_active_surface == 0) ||
				(parsed_mapped &&
				 (parsed_lease_client == 0 || parsed_lease_view == 0)) ||
				(!parsed_mapped &&
				 (parsed_lease_client != 0 || parsed_lease_view != 0)) ||
				(strcmp(presentation_text, "terminal") != 0 &&
				 strcmp(presentation_text, "wayland") != 0 &&
				 strcmp(presentation_text, "game") != 0 &&
				 strcmp(presentation_text, "stream") != 0) ||
				(strcmp(view_mode_text, "console") != 0 &&
				 strcmp(view_mode_text, "presentation") != 0) ||
				strlen(presentation_text) >= sizeof(models[index].presentation) ||
				strlen(view_mode_text) >= sizeof(models[index].view_mode)) {
			free(models);
			snprintf(error, error_size, "snapshot pane model is invalid");
			return false;
		}
		for (size_t previous = 0; previous < index; previous++) {
			if (models[previous].pane_id == parsed_id) {
				free(models);
				snprintf(error, error_size,
					"snapshot contains duplicate pane identity");
				return false;
			}
		}
		models[index].pane_id = (uint32_t)parsed_id;
		models[index].generation = (uint32_t)parsed_generation;
		models[index].left = (uint32_t)parsed_left;
		models[index].top = (uint32_t)parsed_top;
		models[index].columns = (uint32_t)parsed_columns;
		models[index].rows = (uint32_t)parsed_rows;
		models[index].active = json_object_get_boolean(active);
		models[index].visible = json_object_get_boolean(visible);
		models[index].window_active = json_object_get_boolean(window_active);
		strcpy(models[index].presentation, presentation_text);
		strcpy(models[index].view_mode, view_mode_text);
		models[index].presentation_mapped = parsed_mapped;
		models[index].surface_tabs = (uint32_t)parsed_tabs;
		models[index].active_surface_id = (uint32_t)parsed_active_surface;
		models[index].lease_client_id = (uint32_t)parsed_lease_client;
		models[index].lease_view_id = (uint32_t)parsed_lease_view;
	}
	for (size_t index = 0; index < count; index++) {
		for (size_t previous = 0; previous < client->pane_count; previous++) {
			if (models[index].pane_id == client->panes[previous].pane_id &&
					models[index].generation == client->panes[previous].generation) {
				models[index].grid = client->panes[previous].grid;
				memset(&client->panes[previous].grid, 0,
					sizeof(client->panes[previous].grid));
				break;
			}
		}
	}
	for (size_t previous = 0; previous < client->pane_count; previous++) {
		struct engineos_mux_pane_model *source = &client->panes[previous];
		if (!source->grid.ready)
			continue;
		for (size_t view = 0; view < client->view_snapshot_count; view++) {
			struct engineos_mux_view_snapshot *snapshot =
				client->view_snapshots[view];
			for (size_t index = 0; snapshot != NULL &&
					index < snapshot->pane_count; index++) {
				struct engineos_mux_pane_model *replacement =
					&snapshot->panes[index];
				if (replacement->pane_id != source->pane_id ||
						replacement->generation != source->generation ||
						replacement->grid.ready)
					continue;
				if (!clone_grid_model(&source->grid, &replacement->grid)) {
					free_pane_models(models, count);
					snprintf(error, error_size,
						"out of memory preserving output pane grid");
					return false;
				}
			}
		}
	}
	free_pane_models(client->panes, client->pane_count);
	client->panes = models;
	client->pane_count = count;
	return true;
}

static bool request_grid(struct engineos_mux_client *client, char *error,
		size_t error_size) {
	struct engine_mux_grid_request request = {
		.pane_id = htonl(client->pane_id),
		.generation = htonl(client->pane_generation),
	};
	struct engine_mux_frame_header frame = {
		.magic = htonl(ENGINE_MUX_MAGIC),
		.version = htons(ENGINE_MUX_PROTOCOL_VERSION),
		.type = htons(ENGINE_MUX_GRID_REQUEST),
		.request_id = host_to_be64(3),
		.state_revision = host_to_be64(client->revision),
		.payload_length = htonl(sizeof(request)),
	};
	struct iovec parts[] = {
		{.iov_base = &frame, .iov_len = sizeof(frame)},
		{.iov_base = &request, .iov_len = sizeof(request)},
	};
	struct msghdr message = {.msg_iov = parts, .msg_iovlen = 2};
	if (sendmsg(client->fd, &message, MSG_NOSIGNAL) < 0) {
		snprintf(error, error_size, "grid send: %s", strerror(errno));
		return false;
	}
	size_t capacity = sizeof(frame) + ENGINE_MUX_MAX_PAYLOAD;
	unsigned char *packet = malloc(capacity);
	if (packet == NULL) {
		snprintf(error, error_size, "out of memory");
		return false;
	}
receive_again:
	;
	ssize_t count = recv(client->fd, packet, capacity, 0);
	if (count < (ssize_t)sizeof(frame)) {
		free(packet);
		snprintf(error, error_size, "truncated terminal grid");
		return false;
	}
	memcpy(&frame, packet, sizeof(frame));
	uint32_t payload_length = ntohl(frame.payload_length);
	uint16_t type = ntohs(frame.type);
	if (ntohl(frame.magic) != ENGINE_MUX_MAGIC ||
			ntohs(frame.version) != ENGINE_MUX_PROTOCOL_VERSION ||
			payload_length > ENGINE_MUX_MAX_PAYLOAD ||
			sizeof(frame) + payload_length != (size_t)count) {
		free(packet);
		snprintf(error, error_size, "invalid terminal grid frame");
		return false;
	}
	if (type == ENGINE_MUX_GRID_INVALIDATED &&
			payload_length == sizeof(struct engine_mux_grid_request)) {
		struct engine_mux_grid_request notice;
		memcpy(&notice, packet + sizeof(frame), sizeof(notice));
		if (!mark_grid_invalidation(client, ntohl(notice.pane_id),
				ntohl(notice.generation), error, error_size)) {
			free(packet);
			return false;
		}
		goto receive_again;
	}
	if (type == ENGINE_MUX_STATE_INVALIDATED && payload_length == 0) {
		client->state_invalidated_pending = true;
		goto receive_again;
	}
	if (type == ENGINE_MUX_UI_INVALIDATED &&
			payload_length == sizeof(struct engine_mux_ui_invalidation))
		goto receive_again;
	if (ntohl(frame.magic) != ENGINE_MUX_MAGIC ||
			ntohs(frame.version) != ENGINE_MUX_PROTOCOL_VERSION ||
			type != ENGINE_MUX_GRID_SNAPSHOT ||
			payload_length > ENGINE_MUX_MAX_PAYLOAD ||
			sizeof(frame) + payload_length != (size_t)count) {
		free(packet);
		snprintf(error, error_size, "invalid terminal grid frame");
		return false;
	}
	if (payload_length < sizeof(struct engine_mux_grid_header)) {
		free(packet);
		snprintf(error, error_size, "truncated terminal grid");
		return false;
	}
	struct engine_mux_grid_header header;
	memcpy(&header, packet + sizeof(frame), sizeof(header));
	uint32_t columns = ntohl(header.columns);
	uint32_t rows = ntohl(header.rows);
	uint32_t cell_count = ntohl(header.cell_count);
	if (ntohs(header.version) != ENGINE_MUX_GRID_VERSION ||
			ntohl(header.pane_id) != client->pane_id ||
			ntohl(header.generation) != client->pane_generation ||
			(columns != 0 && rows > UINT32_MAX / columns) ||
			cell_count != columns * rows ||
			payload_length != sizeof(header) +
				(size_t)cell_count * sizeof(struct engine_mux_grid_cell)) {
		free(packet);
		snprintf(error, error_size, "terminal grid contract is invalid");
		return false;
	}
	struct engine_mux_grid_cell *cells = malloc(
		(size_t)cell_count * sizeof(*cells));
	if (cells == NULL && cell_count != 0) {
		free(packet);
		snprintf(error, error_size, "out of memory");
		return false;
	}
	memcpy(cells, packet + sizeof(frame) + sizeof(header),
		(size_t)cell_count * sizeof(*cells));
	free(packet);
	free(client->grid_cells);
	client->grid_cells = cells;
	client->grid_revision = be64_to_host(header.grid_revision);
	client->grid_flags = ntohs(header.flags);
	client->grid_columns = columns;
	client->grid_rows = rows;
	client->grid_cursor_x = ntohl(header.cursor_x);
	client->grid_cursor_y = ntohl(header.cursor_y);
	free(client->grid_damage_cells);
	client->grid_damage_cells = NULL;
	client->grid_damage_count = 0;
	client->grid_full_damage = true;
	update_nonblank_count(client);
	return true;
}

static bool request_pane_grid(struct engineos_mux_client *client,
		struct engineos_mux_pane_model *pane, char *error, size_t error_size) {
	struct engine_mux_grid_request request = {
		.pane_id = htonl(pane->pane_id),
		.generation = htonl(pane->generation),
	};
	struct engine_mux_frame_header frame = {
		.magic = htonl(ENGINE_MUX_MAGIC),
		.version = htons(ENGINE_MUX_PROTOCOL_VERSION),
		.type = htons(ENGINE_MUX_GRID_REQUEST),
		.request_id = host_to_be64(13),
		.state_revision = host_to_be64(client->revision),
		.payload_length = htonl(sizeof(request)),
	};
	struct iovec parts[] = {
		{.iov_base = &frame, .iov_len = sizeof(frame)},
		{.iov_base = &request, .iov_len = sizeof(request)},
	};
	struct msghdr message = {.msg_iov = parts, .msg_iovlen = 2};
	if (sendmsg(client->fd, &message, MSG_NOSIGNAL) < 0) {
		snprintf(error, error_size, "pane grid send: %s", strerror(errno));
		return false;
	}
	size_t capacity = sizeof(frame) + ENGINE_MUX_MAX_PAYLOAD;
	unsigned char *packet = malloc(capacity);
	if (packet == NULL) {
		snprintf(error, error_size, "out of memory");
		return false;
	}

receive_again:
	;
	ssize_t count = recv(client->fd, packet, capacity, 0);
	if (count < (ssize_t)sizeof(frame)) {
		free(packet);
		snprintf(error, error_size, "truncated pane terminal grid");
		return false;
	}
	memcpy(&frame, packet, sizeof(frame));
	uint32_t payload_length = ntohl(frame.payload_length);
	uint16_t type = ntohs(frame.type);
	if (ntohl(frame.magic) != ENGINE_MUX_MAGIC ||
			ntohs(frame.version) != ENGINE_MUX_PROTOCOL_VERSION ||
			payload_length > ENGINE_MUX_MAX_PAYLOAD ||
			sizeof(frame) + payload_length != (size_t)count) {
		free(packet);
		snprintf(error, error_size, "invalid pane terminal grid frame");
		return false;
	}
	if (type == ENGINE_MUX_GRID_INVALIDATED &&
			payload_length == sizeof(struct engine_mux_grid_request)) {
		struct engine_mux_grid_request notice;
		memcpy(&notice, packet + sizeof(frame), sizeof(notice));
		if (!mark_grid_invalidation(client, ntohl(notice.pane_id),
				ntohl(notice.generation), error, error_size)) {
			free(packet);
			return false;
		}
		goto receive_again;
	}
	if (type == ENGINE_MUX_UI_INVALIDATED &&
			payload_length == sizeof(struct engine_mux_ui_invalidation))
		goto receive_again;
	if (type == ENGINE_MUX_STATE_INVALIDATED && payload_length == 0) {
		client->state_invalidated_pending = true;
		goto receive_again;
	}
	if (type != ENGINE_MUX_GRID_SNAPSHOT ||
			payload_length < sizeof(struct engine_mux_grid_header)) {
		free(packet);
		snprintf(error, error_size, "unexpected pane terminal grid type %u", type);
		return false;
	}
	struct engine_mux_grid_header header;
	memcpy(&header, packet + sizeof(frame), sizeof(header));
	uint32_t columns = ntohl(header.columns), rows = ntohl(header.rows);
	uint32_t cell_count = ntohl(header.cell_count);
	if (ntohs(header.version) != ENGINE_MUX_GRID_VERSION ||
			ntohl(header.pane_id) != pane->pane_id ||
			ntohl(header.generation) != pane->generation ||
			(columns != 0 && rows > UINT32_MAX / columns) ||
			cell_count != columns * rows || payload_length != sizeof(header) +
				(size_t)cell_count * sizeof(struct engine_mux_grid_cell) ||
			sizeof(frame) + payload_length != (size_t)count) {
		free(packet);
		snprintf(error, error_size, "pane terminal grid contract is invalid");
		return false;
	}
	struct engine_mux_grid_cell *cells = malloc(
		(size_t)cell_count * sizeof(*cells));
	if (cells == NULL && cell_count != 0) {
		free(packet);
		snprintf(error, error_size, "out of memory");
		return false;
	}
	memcpy(cells, packet + sizeof(frame) + sizeof(header),
		(size_t)cell_count * sizeof(*cells));
	free(packet);
	free(pane->grid.cells);
	free(pane->grid.damage_cells);
	pane->grid.cells = cells;
	pane->grid.damage_cells = NULL;
	pane->grid.damage_count = 0;
	pane->grid.revision = be64_to_host(header.grid_revision);
	pane->grid.columns = columns;
	pane->grid.rows = rows;
	pane->columns = columns;
	pane->rows = rows;
	pane->grid.cursor_x = ntohl(header.cursor_x);
	pane->grid.cursor_y = ntohl(header.cursor_y);
	pane->grid.flags = ntohs(header.flags);
	pane->grid.nonblank_cells = grid_nonblank_count(cells, columns, rows);
	pane->grid.full_damage = true;
	pane->grid.ready = true;
	return true;
}

static bool subscribe_grid(struct engineos_mux_client *client, char *error,
		size_t error_size) {
	struct engine_mux_grid_damage_request request = {
		.pane_id = htonl(client->pane_id),
		.generation = htonl(client->pane_generation),
		.grid_revision = host_to_be64(client->grid_revision),
	};
	struct engine_mux_frame_header frame = {
		.magic = htonl(ENGINE_MUX_MAGIC),
		.version = htons(ENGINE_MUX_PROTOCOL_VERSION),
		.type = htons(ENGINE_MUX_GRID_SUBSCRIBE_REQUEST),
		.request_id = host_to_be64(4),
		.state_revision = host_to_be64(client->revision),
		.payload_length = htonl(sizeof(request)),
	};
	struct iovec parts[] = {
		{.iov_base = &frame, .iov_len = sizeof(frame)},
		{.iov_base = &request, .iov_len = sizeof(request)},
	};
	struct msghdr message = {.msg_iov = parts, .msg_iovlen = 2};
	if (sendmsg(client->fd, &message, MSG_NOSIGNAL) < 0) {
		snprintf(error, error_size, "grid subscribe send: %s", strerror(errno));
		return false;
	}
	unsigned char packet[sizeof(frame) + 512];

receive_again:
	;
	ssize_t count = recv(client->fd, packet, sizeof(packet), 0);
	if (count < (ssize_t)sizeof(frame)) {
		snprintf(error, error_size, "truncated grid subscription response");
		return false;
	}
	memcpy(&frame, packet, sizeof(frame));
	uint32_t length = ntohl(frame.payload_length);
	uint16_t type = ntohs(frame.type);
	if (ntohl(frame.magic) != ENGINE_MUX_MAGIC ||
			ntohs(frame.version) != ENGINE_MUX_PROTOCOL_VERSION ||
			length > sizeof(packet) - sizeof(frame) ||
			sizeof(frame) + length != (size_t)count) {
		snprintf(error, error_size, "invalid pane grid subscription frame");
		return false;
	}
	if (type == ENGINE_MUX_GRID_INVALIDATED &&
			length == sizeof(struct engine_mux_grid_request)) {
		struct engine_mux_grid_request notice;
		memcpy(&notice, packet + sizeof(frame), sizeof(notice));
		if (!mark_grid_invalidation(client, ntohl(notice.pane_id),
				ntohl(notice.generation), error, error_size))
			return false;
		goto receive_again;
	}
	if (type == ENGINE_MUX_UI_INVALIDATED &&
			length == sizeof(struct engine_mux_ui_invalidation))
		goto receive_again;
	if (type == ENGINE_MUX_STATE_INVALIDATED && length == 0) {
		client->state_invalidated_pending = true;
		goto receive_again;
	}
	if (ntohl(frame.magic) != ENGINE_MUX_MAGIC ||
			ntohs(frame.version) != ENGINE_MUX_PROTOCOL_VERSION ||
			type != ENGINE_MUX_GRID_SUBSCRIBE_ACK ||
			sizeof(frame) + length != (size_t)count) {
		snprintf(error, error_size, "invalid grid subscription response");
		return false;
	}
	return true;
}

static bool subscribe_pane_grid(struct engineos_mux_client *client,
		struct engineos_mux_pane_model *pane, char *error, size_t error_size) {
	struct engine_mux_grid_damage_request request = {
		.pane_id = htonl(pane->pane_id),
		.generation = htonl(pane->generation),
		.grid_revision = host_to_be64(pane->grid.revision),
	};
	struct engine_mux_frame_header frame = {
		.magic = htonl(ENGINE_MUX_MAGIC),
		.version = htons(ENGINE_MUX_PROTOCOL_VERSION),
		.type = htons(ENGINE_MUX_GRID_SUBSCRIBE_REQUEST),
		.request_id = host_to_be64(14),
		.state_revision = host_to_be64(client->revision),
		.payload_length = htonl(sizeof(request)),
	};
	struct iovec parts[] = {
		{.iov_base = &frame, .iov_len = sizeof(frame)},
		{.iov_base = &request, .iov_len = sizeof(request)},
	};
	struct msghdr message = {.msg_iov = parts, .msg_iovlen = 2};
	if (sendmsg(client->fd, &message, MSG_NOSIGNAL) < 0) {
		snprintf(error, error_size, "pane grid subscribe send: %s",
			strerror(errno));
		return false;
	}
	unsigned char packet[sizeof(frame) + 512];

receive_again:
	;
	ssize_t count = recv(client->fd, packet, sizeof(packet), 0);
	if (count < (ssize_t)sizeof(frame)) {
		snprintf(error, error_size, "truncated pane grid subscription response");
		return false;
	}
	memcpy(&frame, packet, sizeof(frame));
	uint32_t length = ntohl(frame.payload_length);
	uint16_t type = ntohs(frame.type);
	if (ntohl(frame.magic) != ENGINE_MUX_MAGIC ||
			ntohs(frame.version) != ENGINE_MUX_PROTOCOL_VERSION ||
			length > sizeof(packet) - sizeof(frame) ||
			sizeof(frame) + length != (size_t)count) {
		snprintf(error, error_size, "invalid pane grid subscription frame");
		return false;
	}
	if (type == ENGINE_MUX_GRID_INVALIDATED &&
			length == sizeof(struct engine_mux_grid_request)) {
		struct engine_mux_grid_request notice;
		memcpy(&notice, packet + sizeof(frame), sizeof(notice));
		if (!mark_grid_invalidation(client, ntohl(notice.pane_id),
				ntohl(notice.generation), error, error_size))
			return false;
		goto receive_again;
	}
	if (type == ENGINE_MUX_UI_INVALIDATED &&
			length == sizeof(struct engine_mux_ui_invalidation))
		goto receive_again;
	if (type == ENGINE_MUX_STATE_INVALIDATED && length == 0) {
		client->state_invalidated_pending = true;
		goto receive_again;
	}
	if (ntohl(frame.magic) != ENGINE_MUX_MAGIC ||
			ntohs(frame.version) != ENGINE_MUX_PROTOCOL_VERSION ||
			type != ENGINE_MUX_GRID_SUBSCRIBE_ACK ||
			sizeof(frame) + length != (size_t)count) {
		snprintf(error, error_size, "invalid pane grid subscription response");
		return false;
	}
	pane->grid.subscribed = true;
	return true;
}

static bool sync_pane_grids(struct engineos_mux_client *client, char *error,
		size_t error_size) {
	for (size_t index = 0; index < client->pane_count; index++) {
		struct engineos_mux_pane_model *pane = &client->panes[index];
		bool reloaded = false;
		if (!pane->window_active)
			continue;
		if (!pane->grid.ready || pane->grid.columns != pane->columns ||
				pane->grid.rows != pane->rows) {
			if (!request_pane_grid(client, pane, error, error_size))
				return false;
			reloaded = true;
		}
		if ((!pane->grid.subscribed || reloaded) &&
				!subscribe_pane_grid(client, pane, error, error_size))
			return false;
	}
	bool changed = false;
	return service_pending_grid_damage(client, &changed, error, error_size);
}

static bool receive_grid_damage(struct engineos_mux_client *client,
		bool *grid_changed, char *error, size_t error_size) {
	struct engine_mux_grid_damage_request request = {
		.pane_id = htonl(client->pane_id),
		.generation = htonl(client->pane_generation),
		.grid_revision = host_to_be64(client->grid_revision),
	};
	struct engine_mux_frame_header frame = {
		.magic = htonl(ENGINE_MUX_MAGIC),
		.version = htons(ENGINE_MUX_PROTOCOL_VERSION),
		.type = htons(ENGINE_MUX_GRID_DAMAGE_REQUEST),
		.request_id = host_to_be64(5),
		.state_revision = host_to_be64(client->revision),
		.payload_length = htonl(sizeof(request)),
	};
	struct iovec parts[] = {
		{.iov_base = &frame, .iov_len = sizeof(frame)},
		{.iov_base = &request, .iov_len = sizeof(request)},
	};
	struct msghdr message = {.msg_iov = parts, .msg_iovlen = 2};
	if (sendmsg(client->fd, &message, MSG_NOSIGNAL) < 0) {
		snprintf(error, error_size, "grid damage send: %s", strerror(errno));
		return false;
	}
receive_again:
	;
	size_t capacity = sizeof(frame) + ENGINE_MUX_MAX_PAYLOAD;
	unsigned char *packet = malloc(capacity);
	if (packet == NULL) {
		snprintf(error, error_size, "out of memory");
		return false;
	}
	ssize_t count = recv(client->fd, packet, capacity, 0);
	if (count < (ssize_t)sizeof(frame)) {
		free(packet);
		snprintf(error, error_size, "truncated grid damage response");
		return false;
	}
	memcpy(&frame, packet, sizeof(frame));
	uint32_t length = ntohl(frame.payload_length);
	uint16_t type = ntohs(frame.type);
	if (ntohl(frame.magic) != ENGINE_MUX_MAGIC ||
			ntohs(frame.version) != ENGINE_MUX_PROTOCOL_VERSION ||
			length > ENGINE_MUX_MAX_PAYLOAD || sizeof(frame) + length != (size_t)count) {
		free(packet);
		snprintf(error, error_size, "invalid grid damage response");
		return false;
	}
	if (type == ENGINE_MUX_UI_INVALIDATED) {
		if (length != sizeof(struct engine_mux_ui_invalidation)) {
			free(packet);
			snprintf(error, error_size,
				"invalid UI invalidation during grid damage");
			return false;
		}
		free(packet);
		goto receive_again;
	}
	if (type == ENGINE_MUX_ERROR) {
		free(packet);
		if (!request_grid(client, error, error_size)) return false;
		*grid_changed = true;
		return true;
	}
	if (type == ENGINE_MUX_STATE_INVALIDATED && length == 0) {
		free(packet);
		client->state_invalidated_pending = true;
		goto receive_again;
	}
	if (type == ENGINE_MUX_GRID_INVALIDATED &&
			length == sizeof(struct engine_mux_grid_request)) {
		struct engine_mux_grid_request notice;
		memcpy(&notice, packet + sizeof(frame), sizeof(notice));
		free(packet);
		if (!mark_grid_invalidation(client, ntohl(notice.pane_id),
				ntohl(notice.generation), error, error_size))
			return false;
		goto receive_again;
	}
	if (type != ENGINE_MUX_GRID_DAMAGE ||
			length < sizeof(struct engine_mux_grid_damage_header)) {
		free(packet);
		snprintf(error, error_size, "unexpected grid damage response type %u",
			type);
		return false;
	}
	struct engine_mux_grid_damage_header header;
	memcpy(&header, packet + sizeof(frame), sizeof(header));
	uint32_t columns = ntohl(header.grid.columns), rows = ntohl(header.grid.rows);
	uint32_t damage_count = ntohl(header.damage_count);
	if (columns != client->grid_columns || rows != client->grid_rows ||
			length != sizeof(header) +
				(size_t)damage_count * sizeof(struct engine_mux_grid_damage_cell)) {
		free(packet);
		snprintf(error, error_size, "grid damage contract is invalid");
		return false;
	}
	const unsigned char *cursor = packet + sizeof(frame) + sizeof(header);
	struct engineos_mux_damage_cell *render_damage = NULL;
	if (damage_count != 0) {
		render_damage = realloc(client->grid_damage_cells,
			(client->grid_damage_count + damage_count) * sizeof(*render_damage));
		if (render_damage == NULL) {
			free(packet);
			snprintf(error, error_size, "out of memory");
			return false;
		}
		client->grid_damage_cells = render_damage;
	}
	for (uint32_t index = 0; index < damage_count; index++) {
		struct engine_mux_grid_damage_cell damage;
		memcpy(&damage, cursor, sizeof(damage));
		cursor += sizeof(damage);
		uint32_t x = ntohl(damage.x), y = ntohl(damage.y);
		if (x >= columns || y >= rows ||
				damage.cell.text_length > ENGINE_MUX_GRID_CELL_TEXT_MAX) {
			free(packet);
			snprintf(error, error_size, "grid damage cell is invalid");
			return false;
		}
		client->grid_cells[(size_t)y * columns + x] = damage.cell;
		client->grid_damage_cells[client->grid_damage_count + index] =
			(struct engineos_mux_damage_cell){.x = x, .y = y};
	}
	client->grid_damage_count += damage_count;
	uint64_t old_revision = client->grid_revision;
	client->grid_revision = be64_to_host(header.grid.grid_revision);
	client->grid_flags = ntohs(header.grid.flags);
	client->grid_cursor_x = ntohl(header.grid.cursor_x);
	client->grid_cursor_y = ntohl(header.grid.cursor_y);
	client->revision = be64_to_host(frame.state_revision);
	update_nonblank_count(client);
	client->selected_grid_damage_pending = false;
	*grid_changed = damage_count != 0 || client->grid_revision != old_revision;
	free(packet);
	return true;
}

static bool receive_pane_grid_damage(struct engineos_mux_client *client,
		struct engineos_mux_pane_model *pane, bool *grid_changed,
		char *error, size_t error_size) {
	struct engine_mux_grid_damage_request request = {
		.pane_id = htonl(pane->pane_id),
		.generation = htonl(pane->generation),
		.grid_revision = host_to_be64(pane->grid.revision),
	};
	struct engine_mux_frame_header frame = {
		.magic = htonl(ENGINE_MUX_MAGIC),
		.version = htons(ENGINE_MUX_PROTOCOL_VERSION),
		.type = htons(ENGINE_MUX_GRID_DAMAGE_REQUEST),
		.request_id = host_to_be64(15),
		.state_revision = host_to_be64(client->revision),
		.payload_length = htonl(sizeof(request)),
	};
	struct iovec parts[] = {
		{.iov_base = &frame, .iov_len = sizeof(frame)},
		{.iov_base = &request, .iov_len = sizeof(request)},
	};
	struct msghdr message = {.msg_iov = parts, .msg_iovlen = 2};
	if (sendmsg(client->fd, &message, MSG_NOSIGNAL) < 0) {
		snprintf(error, error_size, "pane grid damage send: %s", strerror(errno));
		return false;
	}
	size_t capacity = sizeof(frame) + ENGINE_MUX_MAX_PAYLOAD;
	unsigned char *packet = malloc(capacity);
	if (packet == NULL) {
		snprintf(error, error_size, "out of memory");
		return false;
	}
receive_again:
	;
	ssize_t count = recv(client->fd, packet, capacity, 0);
	if (count < (ssize_t)sizeof(frame)) {
		free(packet);
		snprintf(error, error_size, "truncated pane grid damage response");
		return false;
	}
	memcpy(&frame, packet, sizeof(frame));
	uint32_t length = ntohl(frame.payload_length);
	uint16_t type = ntohs(frame.type);
	if (ntohl(frame.magic) != ENGINE_MUX_MAGIC ||
			ntohs(frame.version) != ENGINE_MUX_PROTOCOL_VERSION ||
			length > ENGINE_MUX_MAX_PAYLOAD ||
			sizeof(frame) + length != (size_t)count) {
		free(packet);
		snprintf(error, error_size, "invalid pane grid damage response");
		return false;
	}
	if (type == ENGINE_MUX_GRID_INVALIDATED &&
			length == sizeof(struct engine_mux_grid_request)) {
		struct engine_mux_grid_request notice;
		memcpy(&notice, packet + sizeof(frame), sizeof(notice));
		if (!mark_grid_invalidation(client, ntohl(notice.pane_id),
				ntohl(notice.generation), error, error_size)) {
			free(packet);
			return false;
		}
		goto receive_again;
	}
	if (type == ENGINE_MUX_STATE_INVALIDATED && length == 0) {
		client->state_invalidated_pending = true;
		goto receive_again;
	}
	if (type == ENGINE_MUX_UI_INVALIDATED)
		goto receive_again;
	if (type == ENGINE_MUX_ERROR) {
		free(packet);
		if (!request_pane_grid(client, pane, error, error_size))
			return false;
		*grid_changed = true;
		return true;
	}
	if (type != ENGINE_MUX_GRID_DAMAGE ||
			length < sizeof(struct engine_mux_grid_damage_header)) {
		free(packet);
		snprintf(error, error_size, "unexpected pane grid damage type %u", type);
		return false;
	}
	struct engine_mux_grid_damage_header header;
	memcpy(&header, packet + sizeof(frame), sizeof(header));
	uint32_t columns = ntohl(header.grid.columns), rows = ntohl(header.grid.rows);
	uint32_t damage_count = ntohl(header.damage_count);
	if (ntohl(header.grid.pane_id) != pane->pane_id ||
			ntohl(header.grid.generation) != pane->generation ||
			columns != pane->grid.columns || rows != pane->grid.rows ||
			length != sizeof(header) + (size_t)damage_count *
				sizeof(struct engine_mux_grid_damage_cell)) {
		free(packet);
		snprintf(error, error_size, "pane grid damage contract is invalid");
		return false;
	}
	struct engineos_mux_damage_cell *render_damage = realloc(
		pane->grid.damage_cells,
		(pane->grid.damage_count + damage_count) * sizeof(*render_damage));
	if (render_damage == NULL && damage_count != 0) {
		free(packet);
		snprintf(error, error_size, "out of memory");
		return false;
	}
	pane->grid.damage_cells = render_damage;
	const unsigned char *cursor = packet + sizeof(frame) + sizeof(header);
	for (uint32_t index = 0; index < damage_count; index++) {
		struct engine_mux_grid_damage_cell damage;
		memcpy(&damage, cursor, sizeof(damage));
		cursor += sizeof(damage);
		uint32_t x = ntohl(damage.x), y = ntohl(damage.y);
		if (x >= columns || y >= rows ||
				damage.cell.text_length > ENGINE_MUX_GRID_CELL_TEXT_MAX) {
			free(packet);
			snprintf(error, error_size, "pane grid damage cell is invalid");
			return false;
		}
		pane->grid.cells[(size_t)y * columns + x] = damage.cell;
		pane->grid.damage_cells[pane->grid.damage_count + index] =
			(struct engineos_mux_damage_cell){.x = x, .y = y};
	}
	pane->grid.damage_count += damage_count;
	uint64_t old_revision = pane->grid.revision;
	pane->grid.revision = be64_to_host(header.grid.grid_revision);
	pane->grid.flags = ntohs(header.grid.flags);
	pane->grid.cursor_x = ntohl(header.grid.cursor_x);
	pane->grid.cursor_y = ntohl(header.grid.cursor_y);
	pane->grid.nonblank_cells = grid_nonblank_count(pane->grid.cells,
		columns, rows);
	pane->grid.damage_pending = false;
	client->revision = be64_to_host(frame.state_revision);
	*grid_changed = damage_count != 0 || pane->grid.revision != old_revision;
	free(packet);
	return true;
}

static bool service_pending_grid_damage(struct engineos_mux_client *client,
		bool *grid_changed, char *error, size_t error_size) {
	bool any_changed = false;
	size_t pane_capacity = client->pane_count;
	for (size_t view = 0; view < client->view_snapshot_count; view++) {
		if (client->view_snapshots[view] != NULL)
			pane_capacity += client->view_snapshots[view]->pane_count;
	}
	for (size_t pass = 0; pass < pane_capacity + 2; pass++) {
		bool serviced = false, changed = false;
		if (client->selected_grid_damage_pending) {
			client->selected_grid_damage_pending = false;
			if (!receive_grid_damage(client, &changed, error, error_size))
				return false;
			any_changed = any_changed || changed;
			serviced = true;
		}
		for (size_t index = 0; index < client->pane_count; index++) {
			struct engineos_mux_pane_model *pane = &client->panes[index];
			if (!pane->grid.damage_pending)
				continue;
			pane->grid.damage_pending = false;
			changed = false;
			if (!receive_pane_grid_damage(client, pane, &changed, error,
					error_size))
				return false;
			any_changed = any_changed || changed;
			serviced = true;
		}
		for (size_t view = 0; view < client->view_snapshot_count; view++) {
			struct engineos_mux_view_snapshot *snapshot =
				client->view_snapshots[view];
			for (size_t index = 0; snapshot != NULL &&
					index < snapshot->pane_count; index++) {
				struct engineos_mux_pane_model *pane =
					&snapshot->panes[index];
				if (!pane->grid.damage_pending)
					continue;
				pane->grid.damage_pending = false;
				changed = false;
				if (!receive_pane_grid_damage(client, pane, &changed,
						error, error_size))
					return false;
				any_changed = any_changed || changed;
				serviced = true;
			}
		}
		if (!serviced) {
			*grid_changed = *grid_changed || any_changed;
			return true;
		}
	}
	snprintf(error, error_size, "grid invalidations did not settle");
	return false;
}

bool engineos_mux_client_connect(struct engineos_mux_client *client,
		const char *socket_path, char *error, size_t error_size) {
	client->fd = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
	if (client->fd < 0) {
		snprintf(error, error_size, "socket: %s", strerror(errno));
		return false;
	}
	struct sockaddr_un address = {.sun_family = AF_UNIX};
	if (strlen(socket_path) >= sizeof(address.sun_path)) {
		snprintf(error, error_size, "socket path is too long");
		engineos_mux_client_destroy(client);
		return false;
	}
	strcpy(address.sun_path, socket_path);
	if (connect(client->fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
		snprintf(error, error_size, "connect %s: %s", socket_path, strerror(errno));
		engineos_mux_client_destroy(client);
		return false;
	}
	client->socket_path = strdup(socket_path);
	if (client->socket_path == NULL) {
		snprintf(error, error_size, "out of memory");
		engineos_mux_client_destroy(client);
		return false;
	}
	if (!exchange(client->fd, ENGINE_MUX_CLIENT_HELLO, 1,
			ENGINE_MUX_SERVER_HELLO, &client->revision,
			"{\"client\":\"engineos-shell\"}", NULL, error, error_size)) {
		engineos_mux_client_destroy(client);
		return false;
	}
	struct json_object *snapshot = NULL;
	if (!exchange(client->fd, ENGINE_MUX_SNAPSHOT_REQUEST, 2,
			ENGINE_MUX_SNAPSHOT, &client->revision,
			"{\"scope\":\"initial-view\"}", &snapshot,
			error, error_size)) {
		engineos_mux_client_destroy(client);
		return false;
	}
	struct json_object *panes = NULL;
	struct json_object *selected = NULL;
	if (!parse_pane_models(client, snapshot, error, error_size)) {
		json_object_put(snapshot);
		engineos_mux_client_destroy(client);
		return false;
	}
	json_object_object_get_ex(snapshot, "panes", &panes);
	for (size_t index = 0; panes != NULL &&
			index < json_object_array_length(panes); index++) {
		struct json_object *pane = json_object_array_get_idx(panes, index);
		struct json_object *window_active = NULL, *active = NULL;
		json_object_object_get_ex(pane, "window_active", &window_active);
		json_object_object_get_ex(pane, "active", &active);
		if (json_object_get_boolean(window_active) &&
				json_object_get_boolean(active)) {
			selected = pane;
			break;
		}
	}
	if (selected == NULL && panes != NULL && json_object_array_length(panes) > 0) {
		selected = json_object_array_get_idx(panes, 0);
	}
	struct json_object *pane_id = NULL, *generation = NULL, *session_id = NULL;
	if (selected == NULL || !json_object_object_get_ex(selected, "pane_id", &pane_id) ||
			!json_object_object_get_ex(selected, "generation", &generation) ||
			!json_object_object_get_ex(selected, "session_id", &session_id)) {
		json_object_put(snapshot);
		snprintf(error, error_size, "snapshot has no selectable pane");
		engineos_mux_client_destroy(client);
		return false;
	}
	const char *pane_text = json_object_get_string(pane_id);
	if (pane_text[0] == '%') pane_text++;
	char *pane_end = NULL;
	unsigned long parsed_pane = strtoul(pane_text, &pane_end, 10);
	client->pane_generation = (uint32_t)json_object_get_int64(generation);
	if (*pane_text == '\0' || *pane_end != '\0' || parsed_pane > UINT32_MAX ||
			client->pane_generation == 0) {
		json_object_put(snapshot);
		snprintf(error, error_size, "snapshot pane identity is invalid");
		engineos_mux_client_destroy(client);
		return false;
	}
	client->pane_id = (uint32_t)parsed_pane;
	if (!parse_pane_presentation(client, selected, error, error_size) ||
			!parse_pane_prefixes(client, selected, error, error_size)) {
		json_object_put(snapshot);
		engineos_mux_client_destroy(client);
		return false;
	}
	client->session_id = strdup(json_object_get_string(session_id));
	if (client->session_id == NULL) {
		json_object_put(snapshot);
		snprintf(error, error_size, "out of memory");
		engineos_mux_client_destroy(client);
		return false;
	}
	json_object_put(snapshot);
	if (!request_grid(client, error, error_size)) {
		engineos_mux_client_destroy(client);
		return false;
	}
	if (!subscribe_grid(client, error, error_size)) {
		engineos_mux_client_destroy(client);
		return false;
	}
	if (!sync_pane_grids(client, error, error_size)) {
		engineos_mux_client_destroy(client);
		return false;
	}
	client->ready = true;
	return true;
}

bool engineos_mux_client_refresh_presentation(struct engineos_mux_client *client,
		char *error, size_t error_size) {
	unsigned int attempts = 0;

refresh_again:
	if (++attempts > 8) {
		snprintf(error, error_size,
			"mux presentation state did not settle");
		return false;
	}
	struct json_object *snapshot = NULL;
	bool grid_changed = false;
	char snapshot_request[128];
	if (client->primary_view_id != 0) {
		snprintf(snapshot_request, sizeof(snapshot_request),
			"{\"schema\":\"engine-mux/snapshot-request-v1\",\"view_id\":%u}",
			client->primary_view_id);
	} else {
		snprintf(snapshot_request, sizeof(snapshot_request), "{}");
	}
	if (!exchange_json_request(client, ENGINE_MUX_SNAPSHOT_REQUEST,
			ENGINE_MUX_SNAPSHOT, snapshot_request,
			"engine-mux/snapshot-v1", &snapshot,
			&grid_changed, error, error_size))
		return false;
	if (client->primary_view_id != 0) {
		uint32_t snapshot_client_id = 0, snapshot_view_id = 0;
		if (!json_u32(snapshot, "snapshot_client_id", UINT32_MAX,
				&snapshot_client_id) ||
				!json_u32(snapshot, "snapshot_view_id", UINT32_MAX,
					&snapshot_view_id) ||
				snapshot_client_id != client->frontend_client_id ||
				snapshot_view_id != client->primary_view_id) {
			json_object_put(snapshot);
			snprintf(error, error_size,
				"snapshot was not scoped to the requested graphical view");
			return false;
		}
	}
	struct json_object *panes = NULL;
	if (!parse_pane_models(client, snapshot, error, error_size)) {
		json_object_put(snapshot);
		return false;
	}
	json_object_object_get_ex(snapshot, "panes", &panes);
	struct json_object *matched = NULL;
	struct json_object *active_any = NULL;
	struct json_object *current = NULL;
	for (size_t index = 0; panes != NULL &&
			index < json_object_array_length(panes); index++) {
		struct json_object *pane = json_object_array_get_idx(panes, index);
		struct json_object *pane_id = NULL, *generation = NULL;
		struct json_object *active = NULL, *window_active = NULL;
		struct json_object *session_id = NULL;
		if (!json_object_object_get_ex(pane, "pane_id", &pane_id) ||
				!json_object_object_get_ex(pane, "generation", &generation) ||
				!json_object_object_get_ex(pane, "active", &active) ||
				!json_object_object_get_ex(pane, "window_active", &window_active) ||
				!json_object_object_get_ex(pane, "session_id", &session_id))
			continue;
		const char *pane_text = json_object_get_string(pane_id);
		if (pane_text[0] == '%') pane_text++;
		char *end = NULL;
		unsigned long parsed = strtoul(pane_text, &end, 10);
		if (*pane_text != '\0' && *end == '\0' &&
				parsed == client->pane_id &&
				json_object_get_int64(generation) == client->pane_generation)
			current = pane;
		if (json_object_get_boolean(active) &&
				json_object_get_boolean(window_active)) {
			active_any = pane;
			if (client->session_id == NULL ||
					strcmp(json_object_get_string(session_id),
					client->session_id) == 0)
				matched = pane;
		}
	}
	if (matched == NULL)
		matched = active_any;
	if (matched == NULL)
		matched = current;
	struct json_object *matched_id = NULL, *matched_generation = NULL;
	struct json_object *matched_session = NULL;
	if (matched == NULL ||
			!json_object_object_get_ex(matched, "pane_id", &matched_id) ||
			!json_object_object_get_ex(matched, "generation", &matched_generation) ||
			!json_object_object_get_ex(matched, "session_id", &matched_session)) {
		json_object_put(snapshot);
		snprintf(error, error_size, "active mux pane disappeared");
		return false;
	}
	const char *matched_text = json_object_get_string(matched_id);
	if (matched_text[0] == '%') matched_text++;
	char *matched_end = NULL;
	unsigned long matched_pane = strtoul(matched_text, &matched_end, 10);
	int64_t matched_generation_value = json_object_get_int64(matched_generation);
	if (*matched_text == '\0' || *matched_end != '\0' ||
			matched_pane > UINT32_MAX || matched_generation_value <= 0 ||
			matched_generation_value > UINT32_MAX) {
		json_object_put(snapshot);
		snprintf(error, error_size, "active mux pane identity is invalid");
		return false;
	}
	const char *matched_session_text = json_object_get_string(matched_session);
	if (matched_session_text == NULL || matched_session_text[0] != '$') {
		json_object_put(snapshot);
		snprintf(error, error_size, "active mux session identity is invalid");
		return false;
	}
	if (client->session_id == NULL ||
			strcmp(client->session_id, matched_session_text) != 0) {
		char *updated_session = strdup(matched_session_text);
		if (updated_session == NULL) {
			json_object_put(snapshot);
			snprintf(error, error_size, "out of memory");
			return false;
		}
		free(client->session_id);
		client->session_id = updated_session;
	}
	bool selection_changed = client->pane_id != (uint32_t)matched_pane ||
		client->pane_generation != (uint32_t)matched_generation_value;
	if (selection_changed) {
		client->pane_id = (uint32_t)matched_pane;
		client->pane_generation = (uint32_t)matched_generation_value;
		client->selected_grid_damage_pending = false;
		if (!request_grid(client, error, error_size) ||
				!subscribe_grid(client, error, error_size)) {
			json_object_put(snapshot);
			return false;
		}
	}
	if (!sync_pane_grids(client, error, error_size)) {
		json_object_put(snapshot);
		return false;
	}
	bool result = matched != NULL &&
		parse_pane_presentation(client, matched, error, error_size) &&
		parse_pane_prefixes(client, matched, error, error_size);
	json_object_put(snapshot);
	if (!result)
		return false;
	if (grid_changed)
		goto refresh_again;
	return true;
}

bool engineos_mux_client_request_view_snapshot(
		struct engineos_mux_client *client, uint32_t view_id,
		struct engineos_mux_view_snapshot *snapshot, bool *grid_changed,
		char *error, size_t error_size) {
	if (view_id == 0 || snapshot == NULL || grid_changed == NULL) {
		snprintf(error, error_size, "invalid graphical view snapshot request");
		return false;
	}
	char request[128];
	snprintf(request, sizeof(request),
		"{\"schema\":\"engine-mux/snapshot-request-v1\",\"view_id\":%u}",
		view_id);
	struct json_object *root = NULL;
	if (!exchange_json_request(client, ENGINE_MUX_SNAPSHOT_REQUEST,
			ENGINE_MUX_SNAPSHOT, request, "engine-mux/snapshot-v1", &root,
			grid_changed, error, error_size))
		return false;

	uint32_t client_id = 0, response_view_id = 0;
	struct json_object *output_object = NULL, *panes_object = NULL;
	if (!json_u32(root, "snapshot_client_id", UINT32_MAX, &client_id) ||
			!json_u32(root, "snapshot_view_id", UINT32_MAX,
				&response_view_id) ||
			client_id != client->frontend_client_id ||
			response_view_id != view_id ||
			!json_object_object_get_ex(root, "snapshot_output", &output_object) ||
			!json_object_is_type(output_object, json_type_string) ||
			!json_object_object_get_ex(root, "panes", &panes_object) ||
			!json_object_is_type(panes_object, json_type_array)) {
		json_object_put(root);
		snprintf(error, error_size,
			"snapshot was not scoped to the requested graphical view");
		return false;
	}

	struct engineos_mux_client parsed = {0};
	parsed.fd = -1;
	if (!parse_pane_models(&parsed, root, error, error_size)) {
		json_object_put(root);
		return false;
	}
	size_t selected = 0;
	for (size_t index = 0; index < parsed.pane_count; index++) {
		if (parsed.panes[index].window_active && parsed.panes[index].active) {
			selected = index;
			break;
		}
	}
	struct json_object *selected_object =
		json_object_array_get_idx(panes_object, selected);
	struct json_object *session_object = NULL;
	const char *output = json_object_get_string(output_object);
	if (selected_object == NULL ||
			!json_object_object_get_ex(selected_object, "session_id",
				&session_object) ||
			!json_object_is_type(session_object, json_type_string)) {
		free_pane_models(parsed.panes, parsed.pane_count);
		json_object_put(root);
		snprintf(error, error_size, "view snapshot has no selected session");
		return false;
	}
	const char *session = json_object_get_string(session_object);
	char *new_output = output != NULL ? strdup(output) : NULL;
	char *new_session = session != NULL ? strdup(session) : NULL;
	if (new_output == NULL || new_output[0] == '\0' || new_session == NULL ||
			new_session[0] != '$') {
		free(new_output);
		free(new_session);
		free_pane_models(parsed.panes, parsed.pane_count);
		json_object_put(root);
		snprintf(error, error_size, "view snapshot identity is invalid");
		return false;
	}

	struct engineos_mux_view_snapshot replacement = {
		.revision = client->revision,
		.client_id = client_id,
		.view_id = response_view_id,
		.pane_id = parsed.panes[selected].pane_id,
		.pane_generation = parsed.panes[selected].generation,
		.output = new_output,
		.session_id = new_session,
		.panes = parsed.panes,
		.pane_count = parsed.pane_count,
		.ready = true,
	};
	json_object_put(root);
	for (size_t index = 0; index < replacement.pane_count; index++) {
		for (size_t previous = 0; previous < snapshot->pane_count; previous++) {
			if (replacement.panes[index].pane_id ==
					snapshot->panes[previous].pane_id &&
					replacement.panes[index].generation ==
					snapshot->panes[previous].generation) {
				replacement.panes[index].grid =
					snapshot->panes[previous].grid;
				memset(&snapshot->panes[previous].grid, 0,
					sizeof(snapshot->panes[previous].grid));
				break;
			}
		}
	}
	engineos_mux_view_snapshot_destroy(snapshot);
	*snapshot = replacement;
	if (!track_view_snapshot(client, snapshot, error, error_size))
		return false;
	for (size_t index = 0; index < snapshot->pane_count; index++) {
		struct engineos_mux_pane_model *pane = &snapshot->panes[index];
		if (pane->grid.ready || find_pane_model(client, pane->pane_id,
				pane->generation) != NULL)
			continue;
		if (!request_pane_grid(client, pane, error, error_size) ||
				!subscribe_pane_grid(client, pane, error, error_size))
			return false;
		pane->grid.subscribed = true;
	}
	return true;
}

struct engineos_mux_pane_model *engineos_mux_client_view_pane_grid(
		struct engineos_mux_client *client,
		const struct engineos_mux_pane_model *pane) {
	if (client == NULL || pane == NULL)
		return NULL;
	return find_pane_model(client, pane->pane_id, pane->generation);
}

bool engineos_mux_client_handle_event(struct engineos_mux_client *client,
		bool *grid_changed, bool *state_changed, char *error,
		size_t error_size) {
	*grid_changed = false;
	*state_changed = false;
	struct engine_mux_frame_header frame;
	unsigned char packet[sizeof(frame) + sizeof(struct engine_mux_grid_request)];
	ssize_t count = recv(client->fd, packet, sizeof(packet), 0);
	if (count < (ssize_t)sizeof(frame)) {
		snprintf(error, error_size, "mux connection closed: %s",
			count == 0 ? "end of stream" : strerror(errno));
		return false;
	}
	memcpy(&frame, packet, sizeof(frame));
	uint32_t length = ntohl(frame.payload_length);
	uint16_t type = ntohs(frame.type);
	if (ntohl(frame.magic) != ENGINE_MUX_MAGIC ||
			ntohs(frame.version) != ENGINE_MUX_PROTOCOL_VERSION ||
			sizeof(frame) + length != (size_t)count) {
		snprintf(error, error_size, "invalid mux invalidation frame");
		return false;
	}
	if (type == ENGINE_MUX_UI_INVALIDATED) {
		struct engine_mux_ui_invalidation invalidated;
		if (length != sizeof(invalidated)) {
			snprintf(error, error_size, "invalid UI invalidation frame");
			return false;
		}
		memcpy(&invalidated, packet + sizeof(frame), sizeof(invalidated));
		uint32_t view_id = ntohl(invalidated.view_id);
		if (view_id != client->primary_view_id) return true;
		bool changed_during_request = false;
		if (!engineos_mux_client_request_ui(client, view_id,
				&changed_during_request, error, error_size)) return false;
		*grid_changed = true;
		return true;
	}
	if (type == ENGINE_MUX_STATE_INVALIDATED && length == 0) {
		*grid_changed = true;
		*state_changed = true;
		return true;
	}
	if (type != ENGINE_MUX_GRID_INVALIDATED ||
			length != sizeof(struct engine_mux_grid_request)) {
		snprintf(error, error_size, "invalid grid invalidation size");
		return false;
	}
	struct engine_mux_grid_request invalidated;
	memcpy(&invalidated, packet + sizeof(frame), sizeof(invalidated));
	uint32_t pane_id = ntohl(invalidated.pane_id);
	uint32_t generation = ntohl(invalidated.generation);
	if (pane_id == client->pane_id && generation == client->pane_generation)
		return receive_grid_damage(client, grid_changed, error, error_size);
	struct engineos_mux_pane_model *pane = find_pane_model(client, pane_id,
		generation);
	if (pane == NULL || !pane->grid.ready || !pane->grid.subscribed) {
		snprintf(error, error_size, "grid invalidation has no retained pane model");
		return false;
	}
	return receive_pane_grid_damage(client, pane, grid_changed, error,
		error_size);
}

bool engineos_mux_client_send_input(struct engineos_mux_client *client,
		const void *bytes, size_t length, bool *grid_changed,
		char *error, size_t error_size) {
	*grid_changed = false;
	if (!client->ready || bytes == NULL || length == 0 ||
			length > ENGINE_MUX_INPUT_MAX) {
		snprintf(error, error_size, "invalid pane input request");
		return false;
	}
	struct engine_mux_input_header request = {
		.pane_id = htonl(client->pane_id),
		.generation = htonl(client->pane_generation),
		.byte_length = htons((uint16_t)length),
	};
	struct engine_mux_frame_header frame = {
		.magic = htonl(ENGINE_MUX_MAGIC),
		.version = htons(ENGINE_MUX_PROTOCOL_VERSION),
		.type = htons(ENGINE_MUX_INPUT_REQUEST),
		.request_id = host_to_be64(6),
		.state_revision = host_to_be64(client->revision),
		.payload_length = htonl((uint32_t)(sizeof(request) + length)),
	};
	struct iovec parts[] = {
		{.iov_base = &frame, .iov_len = sizeof(frame)},
		{.iov_base = &request, .iov_len = sizeof(request)},
		{.iov_base = (void *)bytes, .iov_len = length},
	};
	struct msghdr message = {.msg_iov = parts, .msg_iovlen = 3};
	if (sendmsg(client->fd, &message, MSG_NOSIGNAL) < 0) {
		snprintf(error, error_size, "pane input send: %s", strerror(errno));
		return false;
	}
	for (;;) {
		unsigned char packet[sizeof(frame) + 512];
		ssize_t count = recv(client->fd, packet, sizeof(packet), 0);
		if (count < (ssize_t)sizeof(frame)) {
			snprintf(error, error_size, "truncated pane input response");
			return false;
		}
		memcpy(&frame, packet, sizeof(frame));
		uint32_t payload_length = ntohl(frame.payload_length);
		uint16_t type = ntohs(frame.type);
		if (ntohl(frame.magic) != ENGINE_MUX_MAGIC ||
				ntohs(frame.version) != ENGINE_MUX_PROTOCOL_VERSION ||
				payload_length > sizeof(packet) - sizeof(frame) ||
				sizeof(frame) + payload_length != (size_t)count) {
			snprintf(error, error_size, "invalid pane input response");
			return false;
		}
		if (type == ENGINE_MUX_GRID_INVALIDATED) {
			struct engine_mux_grid_request notice;
			if (payload_length != sizeof(notice)) {
				snprintf(error, error_size, "invalid grid invalidation during input");
				return false;
			}
			memcpy(&notice, packet + sizeof(frame), sizeof(notice));
			if (!mark_grid_invalidation(client, ntohl(notice.pane_id),
					ntohl(notice.generation), error, error_size)) {
				return false;
			}
			continue;
		}
		if (type == ENGINE_MUX_UI_INVALIDATED) {
			if (payload_length != sizeof(struct engine_mux_ui_invalidation)) {
				snprintf(error, error_size, "invalid UI invalidation during request");
				return false;
			}
			continue;
		}
		if (type == ENGINE_MUX_STATE_INVALIDATED && payload_length == 0) {
			client->state_invalidated_pending = true;
			continue;
		}
		if (type == ENGINE_MUX_ERROR) {
			size_t copy_length = payload_length;
			if (copy_length >= error_size) copy_length = error_size - 1;
			memcpy(error, packet + sizeof(frame), copy_length);
			error[copy_length] = '\0';
			return false;
		}
		if (type != ENGINE_MUX_INPUT_ACK) {
			snprintf(error, error_size,
				"unexpected pane input response type %u", type);
			return false;
		}
		client->revision = be64_to_host(frame.state_revision);
		break;
	}
	return service_pending_grid_damage(client, grid_changed, error, error_size);
}

static void free_ui_rows(struct engineos_mux_ui_row *rows, size_t count) {
	for (size_t index = 0; index < count; index++) {
		free(rows[index].text);
		free(rows[index].spans);
	}
	free(rows);
}

static bool json_u32(struct json_object *parent, const char *name,
		uint32_t maximum, uint32_t *value) {
	struct json_object *object = NULL;
	if (!json_object_object_get_ex(parent, name, &object) ||
			!json_object_is_type(object, json_type_int)) return false;
	int64_t parsed = json_object_get_int64(object);
	if (parsed < 0 || (uint64_t)parsed > maximum) return false;
	*value = (uint32_t)parsed;
	return true;
}

static bool json_i32(struct json_object *parent, const char *name,
		int32_t minimum, int32_t maximum, int32_t *value) {
	struct json_object *object = NULL;
	if (!json_object_object_get_ex(parent, name, &object) ||
			!json_object_is_type(object, json_type_int)) return false;
	int64_t parsed = json_object_get_int64(object);
	if (parsed < minimum || parsed > maximum) return false;
	*value = (int32_t)parsed;
	return true;
}

static bool parse_ui_rows(struct json_object *array, uint32_t columns,
		struct engineos_mux_ui_row **parsed_rows, size_t *parsed_count,
		char *error, size_t error_size) {
	if (!json_object_is_type(array, json_type_array)) {
		snprintf(error, error_size, "UI rows are not an array");
		return false;
	}
	size_t count = json_object_array_length(array);
	struct engineos_mux_ui_row *rows = calloc(count, sizeof(*rows));
	if (rows == NULL && count != 0) {
		snprintf(error, error_size, "out of memory");
		return false;
	}
	for (size_t row_index = 0; row_index < count; row_index++) {
		struct json_object *row = json_object_array_get_idx(array, row_index);
		struct json_object *text = NULL, *spans = NULL;
		if (!json_object_is_type(row, json_type_object) ||
				!json_object_object_get_ex(row, "text", &text) ||
				!json_object_is_type(text, json_type_string) ||
				!json_object_object_get_ex(row, "spans", &spans) ||
				!json_object_is_type(spans, json_type_array)) {
			snprintf(error, error_size, "UI row contract is invalid");
			free_ui_rows(rows, count);
			return false;
		}
		rows[row_index].text = strdup(json_object_get_string(text));
		rows[row_index].span_count = json_object_array_length(spans);
		rows[row_index].spans = calloc(rows[row_index].span_count,
			sizeof(*rows[row_index].spans));
		if (rows[row_index].text == NULL ||
				(rows[row_index].spans == NULL && rows[row_index].span_count != 0)) {
			snprintf(error, error_size, "out of memory");
			free_ui_rows(rows, count);
			return false;
		}
		for (size_t span_index = 0;
				span_index < rows[row_index].span_count; span_index++) {
			struct json_object *span = json_object_array_get_idx(spans, span_index);
			struct engineos_mux_ui_span *destination =
				&rows[row_index].spans[span_index];
			uint32_t attributes, foreground, background;
			if (!json_object_is_type(span, json_type_object) ||
					!json_u32(span, "start", columns, &destination->start) ||
					!json_u32(span, "end", columns, &destination->end) ||
					destination->end < destination->start ||
					!json_u32(span, "attributes", UINT16_MAX, &attributes) ||
					!json_u32(span, "foreground", UINT32_MAX, &foreground) ||
					!json_u32(span, "background", UINT32_MAX, &background)) {
				snprintf(error, error_size, "UI style span contract is invalid");
				free_ui_rows(rows, count);
				return false;
			}
			destination->attributes = (uint16_t)attributes;
			destination->foreground = (int32_t)foreground;
			destination->background = (int32_t)background;
		}
	}
	*parsed_rows = rows;
	*parsed_count = count;
	return true;
}

static bool parse_ui_model(struct engineos_mux_client *client,
		struct json_object *root, char *error, size_t error_size) {
	struct json_object *status = NULL, *status_rows = NULL, *mode = NULL;
	struct json_object *prompt = NULL, *message = NULL, *menu = NULL;
	struct json_object *menu_rows = NULL, *active = NULL;
	uint32_t columns, rows, menu_x = 0, menu_y = 0;
	int32_t status_y;
	uint32_t menu_width = 0, menu_height = 0;
	struct engineos_mux_ui_row *new_status_rows = NULL, *new_menu_rows = NULL;
	size_t new_status_count = 0, new_menu_count = 0;
	if (!json_u32(root, "columns", 16384, &columns) || columns == 0 ||
			!json_u32(root, "rows", 16384, &rows) || rows == 0 ||
			!json_object_object_get_ex(root, "status", &status) ||
			!json_object_is_type(status, json_type_object) ||
			!json_object_object_get_ex(status, "mode", &mode) ||
			!json_object_is_type(mode, json_type_string) ||
			strlen(json_object_get_string(mode)) >= sizeof(client->ui_mode) ||
			!json_i32(status, "y", -1, (int32_t)rows, &status_y) ||
			!json_object_object_get_ex(status, "rows", &status_rows) ||
			!parse_ui_rows(status_rows, columns, &new_status_rows,
				&new_status_count, error, error_size) ||
			(status_y < 0 ? new_status_count != 0 :
				(uint64_t)status_y + new_status_count > rows)) {
		if (error[0] == '\0') snprintf(error, error_size, "UI status contract is invalid");
		free_ui_rows(new_status_rows, new_status_count);
		return false;
	}
	if (!json_object_object_get_ex(root, "prompt", &prompt) ||
			!json_object_object_get_ex(prompt, "active", &active) ||
			!json_object_is_type(active, json_type_boolean)) goto invalid;
	bool prompt_active = json_object_get_boolean(active);
	if (!json_object_object_get_ex(root, "message", &message) ||
			!json_object_object_get_ex(message, "active", &active) ||
			!json_object_is_type(active, json_type_boolean)) goto invalid;
	bool message_active = json_object_get_boolean(active);
	if (!json_object_object_get_ex(root, "menu", &menu) ||
			!json_object_object_get_ex(menu, "active", &active) ||
			!json_object_is_type(active, json_type_boolean)) goto invalid;
	bool menu_active = json_object_get_boolean(active);
	if (menu_active) {
		if (!json_u32(menu, "x", columns, &menu_x) ||
				!json_u32(menu, "y", rows, &menu_y) ||
				!json_u32(menu, "width", columns, &menu_width) ||
				!json_u32(menu, "height", rows, &menu_height) ||
				menu_width == 0 || menu_height == 0 ||
				menu_x + menu_width > columns || menu_y + menu_height > rows ||
				!json_object_object_get_ex(menu, "rows", &menu_rows) ||
				!parse_ui_rows(menu_rows, menu_width, &new_menu_rows,
					&new_menu_count, error, error_size) ||
				new_menu_count != menu_height) goto invalid;
	}
	free_ui_rows(client->ui_status_rows, client->ui_status_row_count);
	free_ui_rows(client->ui_menu_rows, client->ui_menu_row_count);
	client->ui_columns = columns;
	client->ui_rows = rows;
	client->ui_status_y = status_y;
	client->ui_status_rows = new_status_rows;
	client->ui_status_row_count = new_status_count;
	client->ui_menu_x = menu_x;
	client->ui_menu_y = menu_y;
	client->ui_menu_width = menu_width;
	client->ui_menu_height = menu_height;
	client->ui_menu_rows = new_menu_rows;
	client->ui_menu_row_count = new_menu_count;
	strcpy(client->ui_mode, json_object_get_string(mode));
	client->ui_prompt_active = prompt_active;
	client->ui_message_active = message_active;
	client->ui_menu_active = menu_active;
	client->ui_changed = true;
	return true;

invalid:
	snprintf(error, error_size, "UI model contract is invalid");
	free_ui_rows(new_status_rows, new_status_count);
	free_ui_rows(new_menu_rows, new_menu_count);
	return false;
}

static bool exchange_json_request(struct engineos_mux_client *client,
		uint16_t request_type, uint16_t expected_type, const char *payload,
		const char *expected_schema, struct json_object **response,
		bool *grid_changed,
		char *error, size_t error_size) {
	*grid_changed = false;
	size_t payload_length = strlen(payload);
	if (!client->ready || payload_length == 0 ||
			payload_length > ENGINE_MUX_MAX_PAYLOAD) {
		snprintf(error, error_size, "invalid mux JSON request");
		return false;
	}
	struct engine_mux_frame_header frame = {
		.magic = htonl(ENGINE_MUX_MAGIC),
		.version = htons(ENGINE_MUX_PROTOCOL_VERSION),
		.type = htons(request_type),
		.request_id = host_to_be64(7),
		.state_revision = host_to_be64(client->revision),
		.payload_length = htonl((uint32_t)payload_length),
	};
	struct iovec parts[] = {
		{.iov_base = &frame, .iov_len = sizeof(frame)},
		{.iov_base = (char *)payload, .iov_len = payload_length},
	};
	struct msghdr message = {.msg_iov = parts, .msg_iovlen = 2};
	if (sendmsg(client->fd, &message, MSG_NOSIGNAL) < 0) {
		snprintf(error, error_size, "mux JSON send: %s", strerror(errno));
		return false;
	}
	for (;;) {
		size_t capacity = sizeof(frame) + ENGINE_MUX_MAX_PAYLOAD;
		unsigned char *packet = malloc(capacity);
		if (packet == NULL) {
			snprintf(error, error_size, "out of memory");
			return false;
		}
		ssize_t count = recv(client->fd, packet, capacity, 0);
		if (count < (ssize_t)sizeof(frame)) {
			free(packet);
			snprintf(error, error_size, "truncated mux JSON response");
			return false;
		}
		memcpy(&frame, packet, sizeof(frame));
		uint32_t length = ntohl(frame.payload_length);
		uint16_t type = ntohs(frame.type);
		if (ntohl(frame.magic) != ENGINE_MUX_MAGIC ||
				ntohs(frame.version) != ENGINE_MUX_PROTOCOL_VERSION ||
				length > ENGINE_MUX_MAX_PAYLOAD ||
				sizeof(frame) + length != (size_t)count) {
			free(packet);
			snprintf(error, error_size, "invalid mux JSON response");
			return false;
		}
		if (type == ENGINE_MUX_GRID_INVALIDATED) {
			struct engine_mux_grid_request notice;
			if (length != sizeof(notice)) {
				free(packet);
				snprintf(error, error_size, "invalid grid invalidation during request");
				return false;
			}
			memcpy(&notice, packet + sizeof(frame), sizeof(notice));
			free(packet);
			if (!mark_grid_invalidation(client, ntohl(notice.pane_id),
					ntohl(notice.generation), error, error_size)) {
				return false;
			}
			continue;
		}
		if (type == ENGINE_MUX_UI_INVALIDATED) {
			if (length != sizeof(struct engine_mux_ui_invalidation)) {
				free(packet);
				snprintf(error, error_size,
					"invalid UI invalidation during request");
				return false;
			}
			free(packet);
			continue;
		}
		if (type == ENGINE_MUX_STATE_INVALIDATED && length == 0) {
			free(packet);
			client->state_invalidated_pending = true;
			*grid_changed = true;
			continue;
		}
		char *json_text = malloc((size_t)length + 1);
		if (json_text == NULL) {
			free(packet);
			snprintf(error, error_size, "out of memory");
			return false;
		}
		memcpy(json_text, packet + sizeof(frame), length);
		json_text[length] = '\0';
		free(packet);
		struct json_object *root = json_tokener_parse(json_text);
		free(json_text);
		if (root == NULL) {
			snprintf(error, error_size,
				"mux response type %u payload is not JSON length=%u",
				type, length);
			return false;
		}
		if (type == ENGINE_MUX_ERROR) {
			struct json_object *message_object = NULL;
			const char *server_message = "mux server rejected request";
			if (json_object_object_get_ex(root, "message", &message_object))
				server_message = json_object_get_string(message_object);
			snprintf(error, error_size, "%s", server_message);
			json_object_put(root);
			return false;
		}
		struct json_object *schema = NULL;
		if (type != expected_type ||
				!json_object_object_get_ex(root, "schema", &schema) ||
				strcmp(json_object_get_string(schema), expected_schema) != 0) {
			snprintf(error, error_size, "unexpected mux JSON response type %u", type);
			json_object_put(root);
			return false;
		}
		if (response != NULL)
			*response = root;
		else
			json_object_put(root);
		client->revision = be64_to_host(frame.state_revision);
		break;
	}
	return service_pending_grid_damage(client, grid_changed, error, error_size);
}

bool engineos_mux_client_register_view(struct engineos_mux_client *client,
		uint32_t view_id, const char *output, uint32_t pixel_width,
		uint32_t pixel_height, uint32_t scale_milli, bool focused,
		bool *grid_changed, char *error, size_t error_size) {
	if (client->session_id == NULL || output == NULL || view_id == 0) {
		snprintf(error, error_size, "invalid graphical view registration");
		return false;
	}
	struct json_object *root = json_object_new_object();
	if (root == NULL) {
		snprintf(error, error_size, "out of memory");
		return false;
	}
	json_object_object_add(root, "schema",
		json_object_new_string("engine-mux/view-register-v1"));
	json_object_object_add(root, "view_id", json_object_new_int64(view_id));
	json_object_object_add(root, "session_id",
		json_object_new_string(client->session_id));
	json_object_object_add(root, "output", json_object_new_string(output));
	json_object_object_add(root, "pixel_width", json_object_new_int64(pixel_width));
	json_object_object_add(root, "pixel_height", json_object_new_int64(pixel_height));
	json_object_object_add(root, "scale_milli", json_object_new_int64(scale_milli));
	json_object_object_add(root, "columns", json_object_new_int64(client->grid_columns));
	json_object_object_add(root, "rows", json_object_new_int64(client->grid_rows));
	json_object_object_add(root, "focused", json_object_new_boolean(focused));
	const char *payload = json_object_to_json_string_ext(root,
		JSON_C_TO_STRING_PLAIN);
	struct json_object *response = NULL;
	bool result = exchange_json_request(client,
		ENGINE_MUX_VIEW_REGISTER_REQUEST, ENGINE_MUX_VIEW_REGISTER_ACK,
		payload, "engine-mux/view-register-v1", &response, grid_changed,
		error, error_size);
	json_object_put(root);
	uint32_t frontend_client_id = 0;
	if (result && (!json_u32(response, "client_id", UINT32_MAX,
			&frontend_client_id) || frontend_client_id == 0 ||
			(client->frontend_client_id != 0 &&
			 client->frontend_client_id != frontend_client_id))) {
		snprintf(error, error_size,
			"graphical view registration client identity is invalid");
		result = false;
	}
	if (response != NULL)
		json_object_put(response);
	if (result)
		client->frontend_client_id = frontend_client_id;
	if (result && focused)
		client->primary_view_id = view_id;
	if (result) {
		result = engineos_mux_client_refresh_presentation(client, error,
			error_size);
		if (result)
			*grid_changed = true;
	}
	return result;
}

bool engineos_mux_client_unregister_view(struct engineos_mux_client *client,
		uint32_t view_id, bool *grid_changed, char *error, size_t error_size) {
	struct json_object *root = json_object_new_object();
	if (root == NULL) {
		snprintf(error, error_size, "out of memory");
		return false;
	}
	json_object_object_add(root, "schema",
		json_object_new_string("engine-mux/view-unregister-v1"));
	json_object_object_add(root, "view_id", json_object_new_int64(view_id));
	const char *payload = json_object_to_json_string_ext(root,
		JSON_C_TO_STRING_PLAIN);
	bool result = exchange_json_request(client,
		ENGINE_MUX_VIEW_UNREGISTER_REQUEST, ENGINE_MUX_VIEW_UNREGISTER_ACK,
		payload, "engine-mux/view-unregister-v1", NULL, grid_changed,
		error, error_size);
	json_object_put(root);
	if (result && client->primary_view_id == view_id)
		client->primary_view_id = 0;
	return result;
}

bool engineos_mux_client_focus_view(struct engineos_mux_client *client,
		uint32_t view_id, bool *grid_changed, char *error, size_t error_size) {
	if (view_id == 0) {
		snprintf(error, error_size, "invalid graphical view focus request");
		return false;
	}
	struct json_object *root = json_object_new_object();
	if (root == NULL) {
		snprintf(error, error_size, "out of memory");
		return false;
	}
	json_object_object_add(root, "schema",
		json_object_new_string("engine-mux/view-focus-v1"));
	json_object_object_add(root, "view_id", json_object_new_int64(view_id));
	const char *payload = json_object_to_json_string_ext(root,
		JSON_C_TO_STRING_PLAIN);
	bool result = exchange_json_request(client,
		ENGINE_MUX_VIEW_FOCUS_REQUEST, ENGINE_MUX_VIEW_FOCUS_ACK,
		payload, "engine-mux/view-focus-v1", NULL, grid_changed,
		error, error_size);
	json_object_put(root);
	if (result) client->primary_view_id = view_id;
	return result;
}

bool engineos_mux_client_send_key(struct engineos_mux_client *client,
		uint32_t view_id, const char *key_name, bool *grid_changed,
		char *error, size_t error_size) {
	if (view_id == 0 || key_name == NULL || *key_name == '\0') {
		snprintf(error, error_size, "invalid graphical key request");
		return false;
	}
	char pane_id[32];
	snprintf(pane_id, sizeof(pane_id), "%%%u", client->pane_id);
	struct json_object *root = json_object_new_object();
	if (root == NULL) {
		snprintf(error, error_size, "out of memory");
		return false;
	}
	json_object_object_add(root, "schema",
		json_object_new_string("engine-mux/key-v1"));
	json_object_object_add(root, "view_id", json_object_new_int64(view_id));
	json_object_object_add(root, "pane_id", json_object_new_string(pane_id));
	json_object_object_add(root, "generation",
		json_object_new_int64(client->pane_generation));
	json_object_object_add(root, "key", json_object_new_string(key_name));
	const char *payload = json_object_to_json_string_ext(root,
		JSON_C_TO_STRING_PLAIN);
	bool result = exchange_json_request(client, ENGINE_MUX_KEY_REQUEST,
		ENGINE_MUX_KEY_ACK, payload, "engine-mux/key-v1", NULL, grid_changed,
		error, error_size);
	json_object_put(root);
	return result;
}

bool engineos_mux_client_send_mouse(struct engineos_mux_client *client,
		uint32_t view_id, uint32_t x, uint32_t y, const char *event,
		const char *button, uint32_t modifiers, bool *grid_changed,
		char *error, size_t error_size) {
	if (view_id == 0 || event == NULL || *event == '\0' ||
			button == NULL || *button == '\0' || modifiers > 7) {
		snprintf(error, error_size, "invalid graphical mouse request");
		return false;
	}
	struct json_object *root = json_object_new_object();
	if (root == NULL) {
		snprintf(error, error_size, "out of memory");
		return false;
	}
	json_object_object_add(root, "schema",
		json_object_new_string("engine-mux/mouse-v1"));
	json_object_object_add(root, "view_id", json_object_new_int64(view_id));
	json_object_object_add(root, "x", json_object_new_int64(x));
	json_object_object_add(root, "y", json_object_new_int64(y));
	json_object_object_add(root, "event", json_object_new_string(event));
	json_object_object_add(root, "button", json_object_new_string(button));
	json_object_object_add(root, "modifiers",
		json_object_new_int64(modifiers));
	const char *payload = json_object_to_json_string_ext(root,
		JSON_C_TO_STRING_PLAIN);
	bool result = exchange_json_request(client, ENGINE_MUX_MOUSE_REQUEST,
		ENGINE_MUX_MOUSE_ACK, payload, "engine-mux/mouse-v1", NULL,
		grid_changed, error, error_size);
	json_object_put(root);
	return result;
}

bool engineos_mux_client_request_ui(struct engineos_mux_client *client,
		uint32_t view_id, bool *grid_changed, char *error, size_t error_size) {
	if (view_id == 0) {
		snprintf(error, error_size, "invalid UI model request");
		return false;
	}
	struct json_object *request = json_object_new_object();
	if (request == NULL) {
		snprintf(error, error_size, "out of memory");
		return false;
	}
	json_object_object_add(request, "schema",
		json_object_new_string("engine-mux/ui-request-v1"));
	json_object_object_add(request, "view_id", json_object_new_int64(view_id));
	const char *payload = json_object_to_json_string_ext(request,
		JSON_C_TO_STRING_PLAIN);
	struct json_object *response = NULL;
	bool result = exchange_json_request(client, ENGINE_MUX_UI_REQUEST,
		ENGINE_MUX_UI_MODEL, payload, "engine-mux/ui-model-v1", &response,
		grid_changed, error, error_size);
	json_object_put(request);
	if (!result) return false;
	result = parse_ui_model(client, response, error, error_size);
	json_object_put(response);
	return result;
}

bool engineos_mux_client_resolve_presentation(struct engineos_mux_client *client,
		int32_t pid, struct engineos_mux_presentation_target *target,
		bool *grid_changed, char *error, size_t error_size) {
	if (pid <= 0 || target == NULL) {
		snprintf(error, error_size, "invalid presentation resolution request");
		return false;
	}
	struct json_object *request = json_object_new_object();
	if (request == NULL) {
		snprintf(error, error_size, "out of memory");
		return false;
	}
	json_object_object_add(request, "schema",
		json_object_new_string("engine-mux/presentation-resolve-v1"));
	json_object_object_add(request, "pid", json_object_new_int64(pid));
	const char *payload = json_object_to_json_string_ext(request,
		JSON_C_TO_STRING_PLAIN);
	struct json_object *response = NULL;
	bool result = exchange_json_request(client,
		ENGINE_MUX_PRESENTATION_RESOLVE_REQUEST,
		ENGINE_MUX_PRESENTATION_RESOLVE, payload,
		"engine-mux/presentation-resolve-v1", &response, grid_changed,
		error, error_size);
	json_object_put(request);
	if (!result)
		return false;
	struct json_object *pane = NULL, *generation = NULL;
	struct json_object *presentation = NULL, *view_mode = NULL;
	if (!json_object_object_get_ex(response, "pane_id", &pane) ||
			!json_object_is_type(pane, json_type_string) ||
			!json_object_object_get_ex(response, "generation", &generation) ||
			!json_object_is_type(generation, json_type_int) ||
			!json_object_object_get_ex(response, "presentation", &presentation) ||
			!json_object_is_type(presentation, json_type_string) ||
			!json_object_object_get_ex(response, "view_mode", &view_mode) ||
			!json_object_is_type(view_mode, json_type_string)) {
		json_object_put(response);
		snprintf(error, error_size, "presentation resolution contract is invalid");
		return false;
	}
	const char *pane_text = json_object_get_string(pane);
	if (pane_text[0] == '%') pane_text++;
	char *pane_end = NULL;
	unsigned long parsed_pane = strtoul(pane_text, &pane_end, 10);
	int64_t parsed_generation = json_object_get_int64(generation);
	const char *parsed_presentation = json_object_get_string(presentation);
	const char *parsed_view_mode = json_object_get_string(view_mode);
	if (*pane_text == '\0' || *pane_end != '\0' || parsed_pane > UINT32_MAX ||
			parsed_generation <= 0 || parsed_generation > UINT32_MAX ||
			strlen(parsed_presentation) >= sizeof(target->presentation) ||
			strlen(parsed_view_mode) >= sizeof(target->view_mode)) {
		json_object_put(response);
		snprintf(error, error_size, "presentation resolution identity is invalid");
		return false;
	}
	memset(target, 0, sizeof(*target));
	target->pane_id = (uint32_t)parsed_pane;
	target->generation = (uint32_t)parsed_generation;
	strcpy(target->presentation, parsed_presentation);
	strcpy(target->view_mode, parsed_view_mode);
	json_object_put(response);
	return true;
}

static bool presentation_surface_request(struct engineos_mux_client *client,
		bool map, uint32_t pane_id, uint32_t generation, int32_t pid,
		uint32_t surface_id, uint32_t view_id, const char *role, bool *grid_changed,
		char *error, size_t error_size) {
	if (generation == 0 || pid <= 0 || surface_id == 0 ||
			(map && (view_id == 0 || role == NULL || *role == '\0'))) {
		snprintf(error, error_size, "invalid presentation surface request");
		return false;
	}
	struct json_object *request = json_object_new_object();
	if (request == NULL) {
		snprintf(error, error_size, "out of memory");
		return false;
	}
	json_object_object_add(request, "schema", json_object_new_string(map ?
		"engine-mux/presentation-map-v1" :
		"engine-mux/presentation-unmap-v1"));
	char pane_name[32];
	snprintf(pane_name, sizeof(pane_name), "%%%u", pane_id);
	json_object_object_add(request, "pane_id", json_object_new_string(pane_name));
	json_object_object_add(request, "generation", json_object_new_int64(generation));
	json_object_object_add(request, "pid", json_object_new_int64(pid));
	json_object_object_add(request, "surface_id", json_object_new_int64(surface_id));
	if (map) {
		json_object_object_add(request, "view_id",
			json_object_new_int64(view_id));
		json_object_object_add(request, "role", json_object_new_string(role));
	}
	const char *payload = json_object_to_json_string_ext(request,
		JSON_C_TO_STRING_PLAIN);
	bool result = exchange_json_request(client,
		map ? ENGINE_MUX_PRESENTATION_MAP_REQUEST :
			ENGINE_MUX_PRESENTATION_UNMAP_REQUEST,
		map ? ENGINE_MUX_PRESENTATION_MAP_ACK :
			ENGINE_MUX_PRESENTATION_UNMAP_ACK,
		payload, map ? "engine-mux/presentation-map-v1" :
			"engine-mux/presentation-unmap-v1", NULL, grid_changed,
		error, error_size);
	json_object_put(request);
	return result;
}

bool engineos_mux_client_map_presentation(struct engineos_mux_client *client,
		const struct engineos_mux_presentation_target *target, int32_t pid,
		uint32_t surface_id, const char *role, bool *grid_changed,
		char *error, size_t error_size) {
	if (target == NULL) {
		snprintf(error, error_size, "presentation target is missing");
		return false;
	}
	return presentation_surface_request(client, true, target->pane_id,
		target->generation, pid, surface_id, client->primary_view_id, role, grid_changed,
		error, error_size);
}

bool engineos_mux_client_unmap_presentation(struct engineos_mux_client *client,
		uint32_t pane_id, uint32_t generation, int32_t pid, uint32_t surface_id,
		bool *grid_changed, char *error, size_t error_size) {
	return presentation_surface_request(client, false, pane_id, generation,
		pid, surface_id, 0, NULL, grid_changed, error, error_size);
}

void engineos_mux_client_clear_render_damage(struct engineos_mux_client *client) {
	free(client->grid_damage_cells);
	client->grid_damage_cells = NULL;
	client->grid_damage_count = 0;
	client->grid_full_damage = false;
	client->ui_changed = false;
}

void engineos_mux_pane_model_clear_render_damage(
		struct engineos_mux_pane_model *pane) {
	free(pane->grid.damage_cells);
	pane->grid.damage_cells = NULL;
	pane->grid.damage_count = 0;
	pane->grid.full_damage = false;
}

void engineos_mux_view_snapshot_destroy(
		struct engineos_mux_view_snapshot *snapshot) {
	if (snapshot == NULL)
		return;
	free(snapshot->output);
	free(snapshot->session_id);
	free_pane_models(snapshot->panes, snapshot->pane_count);
	memset(snapshot, 0, sizeof(*snapshot));
}

void engineos_mux_client_release_view_snapshot(
		struct engineos_mux_client *client,
		struct engineos_mux_view_snapshot *snapshot) {
	if (client == NULL || snapshot == NULL)
		return;
	for (size_t index = 0; index < client->view_snapshot_count; index++) {
		if (client->view_snapshots[index] != snapshot)
			continue;
		memmove(&client->view_snapshots[index],
			&client->view_snapshots[index + 1],
			(client->view_snapshot_count - index - 1) *
			sizeof(*client->view_snapshots));
		client->view_snapshot_count--;
		break;
	}
	for (size_t pane_index = 0; pane_index < snapshot->pane_count;
			pane_index++) {
		struct engineos_mux_pane_model *source =
			&snapshot->panes[pane_index];
		if (!source->grid.ready)
			continue;
		for (size_t view = 0; view < client->view_snapshot_count; view++) {
			struct engineos_mux_view_snapshot *candidate =
				client->view_snapshots[view];
			for (size_t index = 0; candidate != NULL &&
					index < candidate->pane_count; index++) {
				struct engineos_mux_pane_model *replacement =
					&candidate->panes[index];
				if (replacement->pane_id != source->pane_id ||
						replacement->generation != source->generation ||
						replacement->grid.ready)
					continue;
				replacement->grid = source->grid;
				memset(&source->grid, 0, sizeof(source->grid));
				view = client->view_snapshot_count;
				break;
			}
		}
	}
	engineos_mux_view_snapshot_destroy(snapshot);
}

void engineos_mux_client_destroy(struct engineos_mux_client *client) {
	if (client->fd >= 0) {
		close(client->fd);
	}
	client->fd = -1;
	free(client->socket_path);
	free(client->view_snapshots);
	free(client->session_id);
	free(client->grid_cells);
	free_pane_models(client->panes, client->pane_count);
	free(client->grid_damage_cells);
	free_ui_rows(client->ui_status_rows, client->ui_status_row_count);
	free_ui_rows(client->ui_menu_rows, client->ui_menu_row_count);
	client->grid_cells = NULL;
	client->panes = NULL;
	client->pane_count = 0;
	client->grid_damage_cells = NULL;
	client->grid_damage_count = 0;
	client->ui_status_rows = NULL;
	client->ui_status_row_count = 0;
	client->ui_menu_rows = NULL;
	client->ui_menu_row_count = 0;
	client->socket_path = NULL;
	client->view_snapshots = NULL;
	client->view_snapshot_count = 0;
	client->session_id = NULL;
	client->frontend_client_id = 0;
	client->primary_view_id = 0;
	client->ready = false;
}
