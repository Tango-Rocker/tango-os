#include "tmux.h"

#include "engine-mux-frontend.h"
#include "engine-mux-protocol.h"

#include <arpa/inet.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

struct engine_mux_client {
	int fd;
	struct event event;
	u_int subscribed_pane_id;
	u_int subscribed_generation;
	uint64_t subscribed_hash;
	int subscribed;
	int invalidation_pending;
	TAILQ_ENTRY(engine_mux_client) entry;
};

struct engine_mux_grid_state {
	u_int pane_id;
	uint64_t revision;
	u_char *payload;
	size_t payload_size;
	TAILQ_ENTRY(engine_mux_grid_state) entry;
};

static TAILQ_HEAD(, engine_mux_client) engine_mux_clients =
	TAILQ_HEAD_INITIALIZER(engine_mux_clients);
static TAILQ_HEAD(, engine_mux_grid_state) engine_mux_grids =
	TAILQ_HEAD_INITIALIZER(engine_mux_grids);
static struct event engine_mux_accept_event;
static int engine_mux_listener = -1;
static char *engine_mux_socket_path;
static char *engine_mux_snapshot;
static size_t engine_mux_snapshot_size;
static uint64_t engine_mux_revision;
static uint64_t engine_mux_snapshot_hash;

static int engine_mux_send_frame(int, uint16_t, uint64_t, uint64_t,
    const char *, size_t);
static void engine_mux_client_free(struct engine_mux_client *);

static uint64_t
engine_mux_host_to_be64(uint64_t value)
{
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
	return ((uint64_t)htonl((uint32_t)(value >> 32))) |
	    ((uint64_t)htonl((uint32_t)value) << 32);
#else
	return (value);
#endif
}

static uint64_t
engine_mux_be64_to_host(uint64_t value)
{
	return (engine_mux_host_to_be64(value));
}

static void
engine_mux_hash_bytes(uint64_t *hash, const void *data, size_t size)
{
	const u_char *bytes = data;
	size_t i;

	for (i = 0; i < size; i++) {
		*hash ^= bytes[i];
		*hash *= UINT64_C(1099511628211);
	}
}

static void
engine_mux_hash_string(uint64_t *hash, const char *value)
{
	if (value != NULL)
		engine_mux_hash_bytes(hash, value, strlen(value));
	engine_mux_hash_bytes(hash, "\0", 1);
}

static void
engine_mux_json_string(struct evbuffer *buffer, const char *value)
{
	const u_char *cursor;

	evbuffer_add(buffer, "\"", 1);
	if (value != NULL) {
		for (cursor = (const u_char *)value; *cursor != '\0'; cursor++) {
			switch (*cursor) {
			case '\\':
				evbuffer_add(buffer, "\\\\", 2);
				break;
			case '\"':
				evbuffer_add(buffer, "\\\"", 2);
				break;
			case '\b':
				evbuffer_add(buffer, "\\b", 2);
				break;
			case '\f':
				evbuffer_add(buffer, "\\f", 2);
				break;
			case '\n':
				evbuffer_add(buffer, "\\n", 2);
				break;
			case '\r':
				evbuffer_add(buffer, "\\r", 2);
				break;
			case '\t':
				evbuffer_add(buffer, "\\t", 2);
				break;
			default:
				if (*cursor < 0x20)
					evbuffer_add_printf(buffer, "\\u%04x", *cursor);
				else
					evbuffer_add(buffer, cursor, 1);
				break;
			}
		}
	}
	evbuffer_add(buffer, "\"", 1);
}

static char *
engine_mux_current_command(struct window_pane *wp)
{
	char *command, *name;

	command = osdep_get_name(wp->fd, wp->tty);
	if (command == NULL || *command == '\0') {
		free(command);
		command = cmd_stringify_argv(wp->argc, wp->argv);
		if (command == NULL || *command == '\0') {
			free(command);
			command = xstrdup(wp->shell == NULL ? "" : wp->shell);
		}
	}
	name = parse_window_name(command);
	free(command);
	return (name);
}

static char *
engine_mux_build_snapshot(uint64_t revision, uint64_t *content_hash,
    size_t *size)
{
	struct evbuffer *buffer;
	struct session *session;
	struct winlink *winlink;
	struct window *window;
	struct window_pane *pane;
	char *layout, *command;
	char *result;
	int first = 1, pane_active, window_active, copy_mode;
	uint64_t hash = UINT64_C(1469598103934665603);

	buffer = evbuffer_new();
	if (buffer == NULL)
		fatalx("engine mux snapshot allocation failed");
	evbuffer_add_printf(buffer,
	    "{\"schema\":\"engine-mux/snapshot-v1\",\"revision\":%llu,\"panes\":[",
	    (unsigned long long)revision);

	RB_FOREACH(session, sessions, &sessions) {
		RB_FOREACH(winlink, winlinks, &session->windows) {
			window = winlink->window;
			window_active = session->curw == winlink;
			layout = layout_dump(window->layout_root);
			TAILQ_FOREACH(pane, &window->panes, entry) {
				pane_active = window->active == pane;
				copy_mode = pane->screen != &pane->base;
				command = engine_mux_current_command(pane);
				if (!first)
					evbuffer_add(buffer, ",", 1);
				first = 0;
				evbuffer_add_printf(buffer,
				    "{\"session_id\":\"$%u\",\"session_name\":",
				    session->id);
				engine_mux_json_string(buffer, session->name);
				evbuffer_add_printf(buffer,
				    ",\"window_id\":\"@%u\",\"window_index\":%d,\"window_active\":%s,\"window_layout\":",
				    window->id, winlink->idx,
				    window_active ? "true" : "false");
				engine_mux_json_string(buffer, layout);
				evbuffer_add_printf(buffer,
				    ",\"pane_id\":\"%%%u\",\"generation\":1,\"pid\":%lld,\"tty\":",
				    pane->id, (long long)pane->pid);
				engine_mux_json_string(buffer, pane->tty);
				evbuffer_add_printf(buffer,
				    ",\"columns\":%u,\"rows\":%u,\"history_rows\":%u,\"history_scrolled\":%u,\"copy_mode\":%s,\"active\":%s,\"command\":",
				    pane->sx, pane->sy,
				    pane->base.grid->hsize, pane->base.grid->hscrolled,
				    copy_mode ? "true" : "false",
				    pane_active ? "true" : "false");
				engine_mux_json_string(buffer, command);
				evbuffer_add(buffer, ",\"title\":", 9);
				engine_mux_json_string(buffer, pane->base.title);
				evbuffer_add_printf(buffer,
				    ",\"presentation\":\"terminal\",\"view_mode\":\"presentation\"}");

				engine_mux_hash_bytes(&hash, &session->id,
				    sizeof session->id);
				engine_mux_hash_string(&hash, session->name);
				engine_mux_hash_bytes(&hash, &window->id,
				    sizeof window->id);
				engine_mux_hash_bytes(&hash, &winlink->idx,
				    sizeof winlink->idx);
				engine_mux_hash_bytes(&hash, &window_active,
				    sizeof window_active);
				engine_mux_hash_string(&hash, layout);
				engine_mux_hash_bytes(&hash, &pane->id,
				    sizeof pane->id);
				engine_mux_hash_bytes(&hash, &pane->pid,
				    sizeof pane->pid);
				engine_mux_hash_string(&hash, pane->tty);
				engine_mux_hash_bytes(&hash, &pane->sx,
				    sizeof pane->sx);
				engine_mux_hash_bytes(&hash, &pane->sy,
				    sizeof pane->sy);
				engine_mux_hash_bytes(&hash, &pane->base.grid->hsize,
				    sizeof pane->base.grid->hsize);
				engine_mux_hash_bytes(&hash, &pane->base.grid->hscrolled,
				    sizeof pane->base.grid->hscrolled);
				engine_mux_hash_bytes(&hash, &copy_mode,
				    sizeof copy_mode);
				engine_mux_hash_bytes(&hash, &pane_active,
				    sizeof pane_active);
				engine_mux_hash_string(&hash, command);
				engine_mux_hash_string(&hash, pane->base.title);
				free(command);
			}
			free(layout);
		}
	}
	evbuffer_add(buffer, "]}", 2);
	*size = EVBUFFER_LENGTH(buffer);
	result = xmalloc(*size + 1);
	memcpy(result, EVBUFFER_DATA(buffer), *size);
	result[*size] = '\0';
	evbuffer_free(buffer);
	*content_hash = hash;
	return (result);
}

static void
engine_mux_encode_cell(struct engine_mux_grid_cell *wire_cell,
    struct grid_cell *cell)
{
	wire_cell->attributes = htons(cell->attr);
	wire_cell->flags = cell->flags;
	wire_cell->width = cell->data.width;
	wire_cell->text_length = cell->data.have;
	wire_cell->foreground = htonl((uint32_t)cell->fg);
	wire_cell->background = htonl((uint32_t)cell->bg);
	wire_cell->underline_colour = htonl((uint32_t)cell->us);
	wire_cell->hyperlink = htonl(cell->link);
	memcpy(wire_cell->text, cell->data.data, cell->data.have);
}

static u_char *
engine_mux_build_grid(struct window_pane *pane, size_t *size)
{
	struct screen *screen = pane->screen;
	struct engine_mux_grid_header *header;
	struct engine_mux_grid_cell *wire_cell;
	struct grid_cell cell;
	u_char *payload;
	u_int x, y, columns, rows;
	size_t cell_count;
	uint16_t flags = 0;

	columns = screen_size_x(screen);
	rows = screen_size_y(screen);
	if (columns != 0 && rows > SIZE_MAX / columns) {
		errno = EMSGSIZE;
		return (NULL);
	}
	cell_count = (size_t)columns * rows;
	if (cell_count > (ENGINE_MUX_MAX_PAYLOAD - sizeof *header) /
	    sizeof *wire_cell) {
		errno = EMSGSIZE;
		return (NULL);
	}
	*size = sizeof *header + cell_count * sizeof *wire_cell;
	payload = xcalloc(1, *size);
	header = (struct engine_mux_grid_header *)payload;
	if (SCREEN_IS_ALTERNATE(&pane->base))
		flags |= ENGINE_MUX_GRID_ALTERNATE;
	if (screen->mode & MODE_CURSOR)
		flags |= ENGINE_MUX_GRID_CURSOR_VISIBLE;
	header->version = htons(ENGINE_MUX_GRID_VERSION);
	header->flags = htons(flags);
	header->pane_id = htonl(pane->id);
	header->generation = htonl(1);
	header->columns = htonl(columns);
	header->rows = htonl(rows);
	header->cursor_x = htonl(screen->cx);
	header->cursor_y = htonl(screen->cy);
	header->cursor_style = htons(screen->cstyle);
	header->cursor_colour = htonl((uint32_t)screen->ccolour);
	header->screen_mode = htonl((uint32_t)screen->mode);
	header->cell_count = htonl((uint32_t)cell_count);
	wire_cell = (struct engine_mux_grid_cell *)(header + 1);
	for (y = 0; y < rows; y++) {
		for (x = 0; x < columns; x++, wire_cell++) {
			grid_view_get_cell(screen->grid, x, y, &cell);
			engine_mux_encode_cell(wire_cell, &cell);
		}
	}
	return (payload);
}

static u_char *
engine_mux_build_scrollback(struct window_pane *pane, u_int start,
    u_int count, size_t *size)
{
	struct grid *grid = pane->base.grid;
	struct engine_mux_scrollback_header *header;
	struct engine_mux_grid_cell *wire_cell;
	struct grid_cell cell;
	u_char *payload;
	u_int x, y, columns = grid->sx;
	size_t cell_count;

	if (start > grid->hsize || count > grid->hsize - start) {
		errno = ERANGE;
		return (NULL);
	}
	cell_count = (size_t)columns * count;
	if (columns != 0 && cell_count / columns != count) {
		errno = EMSGSIZE;
		return (NULL);
	}
	if (cell_count > (ENGINE_MUX_MAX_PAYLOAD - sizeof *header) /
	    sizeof *wire_cell) {
		errno = EMSGSIZE;
		return (NULL);
	}
	*size = sizeof *header + cell_count * sizeof *wire_cell;
	payload = xcalloc(1, *size);
	header = (struct engine_mux_scrollback_header *)payload;
	header->version = htons(ENGINE_MUX_GRID_VERSION);
	header->pane_id = htonl(pane->id);
	header->generation = htonl(1);
	header->columns = htonl(columns);
	header->total_rows = htonl(grid->hsize);
	header->start_row = htonl(start);
	header->row_count = htonl(count);
	header->cell_count = htonl((uint32_t)cell_count);
	wire_cell = (struct engine_mux_grid_cell *)(header + 1);
	for (y = start; y < start + count; y++) {
		for (x = 0; x < columns; x++, wire_cell++) {
			grid_get_cell(grid, x, y, &cell);
			engine_mux_encode_cell(wire_cell, &cell);
		}
	}
	return (payload);
}

static void
engine_mux_notify_grid_clients(void)
{
	struct engine_mux_client *client, *next;
	struct engine_mux_grid_request invalidated;
	struct window_pane *pane;
	u_char *payload;
	size_t payload_size;
	uint64_t hash;

	TAILQ_FOREACH_SAFE(client, &engine_mux_clients, entry, next) {
		if (!client->subscribed || client->invalidation_pending)
			continue;
		pane = window_pane_find_by_id(client->subscribed_pane_id);
		if (pane == NULL) {
			engine_mux_client_free(client);
			continue;
		}
		payload = engine_mux_build_grid(pane, &payload_size);
		if (payload == NULL)
			continue;
		hash = UINT64_C(1469598103934665603);
		engine_mux_hash_bytes(&hash, payload, payload_size);
		free(payload);
		if (hash == client->subscribed_hash)
			continue;
		invalidated.pane_id = htonl(client->subscribed_pane_id);
		invalidated.generation = htonl(client->subscribed_generation);
		if (engine_mux_send_frame(client->fd, ENGINE_MUX_GRID_INVALIDATED,
		    0, engine_mux_revision, (char *)&invalidated,
		    sizeof invalidated) != 0) {
			if (errno != EAGAIN && errno != EWOULDBLOCK)
				engine_mux_client_free(client);
			continue;
		}
		client->subscribed_hash = hash;
		client->invalidation_pending = 1;
	}
}

static struct engine_mux_grid_state *
engine_mux_grid_find(u_int pane_id)
{
	struct engine_mux_grid_state *state;

	TAILQ_FOREACH(state, &engine_mux_grids, entry) {
		if (state->pane_id == pane_id)
			return (state);
	}
	return (NULL);
}

static struct engine_mux_grid_state *
engine_mux_grid_sync(struct window_pane *pane, u_char **candidate,
    size_t *candidate_size)
{
	struct engine_mux_grid_state *state;

	*candidate = engine_mux_build_grid(pane, candidate_size);
	if (*candidate == NULL)
		return (NULL);
	state = engine_mux_grid_find(pane->id);
	if (state == NULL) {
		state = xcalloc(1, sizeof *state);
		state->pane_id = pane->id;
		state->revision = 1;
		state->payload = *candidate;
		state->payload_size = *candidate_size;
		*candidate = NULL;
		TAILQ_INSERT_TAIL(&engine_mux_grids, state, entry);
	}
	return (state);
}

static int
engine_mux_send_full_grid(struct engine_mux_client *client,
    struct window_pane *pane, uint64_t request_id)
{
	struct engine_mux_grid_state *state;
	struct engine_mux_grid_header *header;
	u_char *candidate;
	size_t candidate_size;
	int result;

	state = engine_mux_grid_sync(pane, &candidate, &candidate_size);
	if (state == NULL)
		return (-1);
	if (candidate != NULL) {
		if (candidate_size != state->payload_size ||
		    memcmp(candidate, state->payload, candidate_size) != 0) {
			state->revision++;
			free(state->payload);
			state->payload = candidate;
			state->payload_size = candidate_size;
			candidate = NULL;
		}
		free(candidate);
	}
	header = (struct engine_mux_grid_header *)state->payload;
	header->grid_revision = engine_mux_host_to_be64(state->revision);
	result = engine_mux_send_frame(client->fd, ENGINE_MUX_GRID_SNAPSHOT,
	    request_id, engine_mux_revision, (char *)state->payload,
	    state->payload_size);
	header->grid_revision = 0;
	return (result);
}

static int
engine_mux_send_grid_damage(struct engine_mux_client *client,
    struct window_pane *pane, uint64_t request_id, uint64_t base_revision)
{
	struct engine_mux_grid_state *state;
	struct engine_mux_grid_header *old_header, *new_header;
	struct engine_mux_grid_damage_header *damage_header;
	struct engine_mux_grid_cell *old_cell, *new_cell;
	struct engine_mux_grid_damage_cell *damage_cell;
	u_char *candidate, *damage;
	size_t candidate_size, damage_size;
	u_int x, y, columns, rows;
	uint32_t damage_count = 0;
	int result;

	state = engine_mux_grid_find(pane->id);
	if (state == NULL || state->revision != base_revision) {
		errno = ESTALE;
		return (-1);
	}
	candidate = engine_mux_build_grid(pane, &candidate_size);
	if (candidate == NULL)
		return (-1);
	if (candidate_size != state->payload_size) {
		free(candidate);
		errno = ESTALE;
		return (-1);
	}
	old_header = (struct engine_mux_grid_header *)state->payload;
	new_header = (struct engine_mux_grid_header *)candidate;
	columns = ntohl(new_header->columns);
	rows = ntohl(new_header->rows);
	old_cell = (struct engine_mux_grid_cell *)(old_header + 1);
	new_cell = (struct engine_mux_grid_cell *)(new_header + 1);
	for (y = 0; y < rows; y++) {
		for (x = 0; x < columns; x++) {
			if (memcmp(old_cell, new_cell, sizeof *old_cell) != 0)
				damage_count++;
			old_cell++;
			new_cell++;
		}
	}
	damage_size = sizeof *damage_header +
	    (size_t)damage_count * sizeof *damage_cell;
	if (damage_size > ENGINE_MUX_MAX_PAYLOAD) {
		free(candidate);
		errno = ESTALE;
		return (-1);
	}
	damage = xcalloc(1, damage_size);
	damage_header = (struct engine_mux_grid_damage_header *)damage;
	memcpy(&damage_header->grid, new_header, sizeof *new_header);
	damage_header->damage_count = htonl(damage_count);
	old_cell = (struct engine_mux_grid_cell *)(old_header + 1);
	new_cell = (struct engine_mux_grid_cell *)(new_header + 1);
	damage_cell = (struct engine_mux_grid_damage_cell *)(damage_header + 1);
	for (y = 0; y < rows; y++) {
		for (x = 0; x < columns; x++) {
			if (memcmp(old_cell, new_cell, sizeof *old_cell) != 0) {
				damage_cell->x = htonl(x);
				damage_cell->y = htonl(y);
				memcpy(&damage_cell->cell, new_cell,
				    sizeof damage_cell->cell);
				damage_cell++;
			}
			old_cell++;
			new_cell++;
		}
	}
	if (memcmp(state->payload, candidate, candidate_size) != 0)
		state->revision++;
	damage_header->grid.grid_revision =
	    engine_mux_host_to_be64(state->revision);
	free(state->payload);
	state->payload = candidate;
	state->payload_size = candidate_size;
	result = engine_mux_send_frame(client->fd, ENGINE_MUX_GRID_DAMAGE,
	    request_id, engine_mux_revision, (char *)damage, damage_size);
	free(damage);
	return (result);
}

void
engine_mux_frontend_sync(void)
{
	char *candidate;
	size_t candidate_size;
	uint64_t content_hash;

	if (engine_mux_listener == -1)
		return;

	candidate = engine_mux_build_snapshot(engine_mux_revision,
	    &content_hash, &candidate_size);
	if (engine_mux_snapshot != NULL &&
	    content_hash == engine_mux_snapshot_hash) {
		free(candidate);
		engine_mux_notify_grid_clients();
		return;
	}
	if (engine_mux_revision == 0)
		engine_mux_revision = 1;
	else
		engine_mux_revision++;
	free(candidate);
	candidate = engine_mux_build_snapshot(engine_mux_revision,
	    &content_hash, &candidate_size);
	free(engine_mux_snapshot);
	engine_mux_snapshot = candidate;
	engine_mux_snapshot_size = candidate_size;
	engine_mux_snapshot_hash = content_hash;
	engine_mux_notify_grid_clients();
}

static int
engine_mux_send_frame(int fd, uint16_t type, uint64_t request_id,
    uint64_t revision, const char *payload, size_t payload_size)
{
	struct engine_mux_frame_header header;
	struct iovec parts[2];
	struct msghdr message;

	if (payload_size > ENGINE_MUX_MAX_PAYLOAD) {
		errno = EMSGSIZE;
		return (-1);
	}
	memset(&header, 0, sizeof header);
	header.magic = htonl(ENGINE_MUX_MAGIC);
	header.version = htons(ENGINE_MUX_PROTOCOL_VERSION);
	header.type = htons(type);
	header.request_id = engine_mux_host_to_be64(request_id);
	header.state_revision = engine_mux_host_to_be64(revision);
	header.payload_length = htonl((uint32_t)payload_size);
	parts[0].iov_base = &header;
	parts[0].iov_len = sizeof header;
	parts[1].iov_base = (void *)payload;
	parts[1].iov_len = payload_size;
	memset(&message, 0, sizeof message);
	message.msg_iov = parts;
	message.msg_iovlen = payload_size == 0 ? 1 : 2;
	if (sendmsg(fd, &message, MSG_NOSIGNAL) == -1)
		return (-1);
	return (0);
}

static int
engine_mux_send_error(int fd, uint64_t request_id, const char *code,
    const char *message)
{
	struct evbuffer *buffer;
	const char *payload;
	size_t payload_size;
	int result;

	buffer = evbuffer_new();
	if (buffer == NULL)
		return (-1);
	evbuffer_add(buffer, "{\"code\":", 8);
	engine_mux_json_string(buffer, code);
	evbuffer_add(buffer, ",\"message\":", 11);
	engine_mux_json_string(buffer, message);
	evbuffer_add(buffer, "}", 1);
	payload = (const char *)EVBUFFER_DATA(buffer);
	payload_size = EVBUFFER_LENGTH(buffer);
	result = engine_mux_send_frame(fd, ENGINE_MUX_ERROR, request_id,
	    engine_mux_revision, payload, payload_size);
	evbuffer_free(buffer);
	return (result);
}

static void
engine_mux_client_free(struct engine_mux_client *client)
{
	event_del(&client->event);
	TAILQ_REMOVE(&engine_mux_clients, client, entry);
	close(client->fd);
	free(client);
}

static void
engine_mux_client_event(__unused int fd, __unused short events, void *data)
{
	struct engine_mux_client *client = data;
	struct engine_mux_frame_header header;
	u_char *packet;
	ssize_t received;
	size_t packet_size;
	uint32_t payload_size;
	uint16_t type;
	uint64_t request_id, request_revision;
	struct engine_mux_grid_request grid_request;
	struct engine_mux_grid_damage_request damage_request;
	struct engine_mux_scrollback_request scrollback_request;
	struct window_pane *pane;
	u_char *scrollback;
	size_t scrollback_size;
	const char *hello =
	    "{\"schema\":\"engine-mux/hello-v1\",\"server\":\"engine-mux\","
	    "\"tmux_baseline\":\"3.6b\",\"capabilities\":[\"layout-snapshot\",\"terminal-grid-v1\",\"grid-subscribe-v1\"]}";
	const char *subscribe_ack =
	    "{\"schema\":\"engine-mux/grid-subscribe-v1\",\"subscribed\":true}";

	packet_size = sizeof header + ENGINE_MUX_MAX_PAYLOAD;
	packet = xmalloc(packet_size);
	received = recv(client->fd, packet, packet_size, 0);
	if (received <= 0) {
		free(packet);
		engine_mux_client_free(client);
		return;
	}
	if ((size_t)received < sizeof header) {
		free(packet);
		if (engine_mux_send_error(client->fd, 0, "malformed-frame",
		    "frame header is truncated") != 0)
			engine_mux_client_free(client);
		return;
	}
	memcpy(&header, packet, sizeof header);
	request_id = engine_mux_be64_to_host(header.request_id);
	payload_size = ntohl(header.payload_length);
	if (ntohl(header.magic) != ENGINE_MUX_MAGIC) {
		free(packet);
		if (engine_mux_send_error(client->fd, request_id, "bad-magic",
		    "frame magic is invalid") != 0)
			engine_mux_client_free(client);
		return;
	}
	if (ntohs(header.version) != ENGINE_MUX_PROTOCOL_VERSION) {
		free(packet);
		if (engine_mux_send_error(client->fd, request_id,
		    "version-mismatch", "protocol version is unsupported") != 0)
			engine_mux_client_free(client);
		return;
	}
	if (payload_size > ENGINE_MUX_MAX_PAYLOAD ||
	    sizeof header + payload_size != (size_t)received) {
		free(packet);
		if (engine_mux_send_error(client->fd, request_id,
		    "malformed-frame", "payload length does not match packet") != 0)
			engine_mux_client_free(client);
		return;
	}
	type = ntohs(header.type);
	request_revision = engine_mux_be64_to_host(header.state_revision);
	if (type == ENGINE_MUX_CLIENT_HELLO) {
		free(packet);
		if (engine_mux_send_frame(client->fd, ENGINE_MUX_SERVER_HELLO,
		    request_id, engine_mux_revision, hello, strlen(hello)) != 0)
			engine_mux_client_free(client);
		return;
	}
	if (type == ENGINE_MUX_SNAPSHOT_REQUEST) {
		free(packet);
		engine_mux_frontend_sync();
		if (engine_mux_send_frame(client->fd, ENGINE_MUX_SNAPSHOT,
		    request_id, engine_mux_revision, engine_mux_snapshot,
		    engine_mux_snapshot_size) != 0)
			engine_mux_client_free(client);
		return;
	}
	if (type == ENGINE_MUX_GRID_REQUEST) {
		if (payload_size != sizeof grid_request) {
			free(packet);
			if (engine_mux_send_error(client->fd, request_id,
			    "malformed-grid-request", "grid request has the wrong size") != 0)
				engine_mux_client_free(client);
			return;
		}
		memcpy(&grid_request, packet + sizeof header, sizeof grid_request);
		free(packet);
		if (ntohl(grid_request.generation) != 1) {
			if (engine_mux_send_error(client->fd, request_id,
			    "stale-generation", "pane generation is not current") != 0)
				engine_mux_client_free(client);
			return;
		}
		pane = window_pane_find_by_id(ntohl(grid_request.pane_id));
		if (pane == NULL) {
			if (engine_mux_send_error(client->fd, request_id,
			    "pane-not-found", "pane does not exist") != 0)
				engine_mux_client_free(client);
			return;
		}
		if (engine_mux_send_full_grid(client, pane, request_id) != 0) {
			if (errno != EMSGSIZE) {
				engine_mux_client_free(client);
				return;
			}
			if (engine_mux_send_error(client->fd, request_id,
			    "grid-too-large", "pane grid exceeds the protocol payload limit") != 0)
				engine_mux_client_free(client);
		} else if (client->subscribed &&
		    client->subscribed_pane_id == pane->id) {
			struct engine_mux_grid_state *state =
			    engine_mux_grid_find(pane->id);
			client->subscribed_hash = UINT64_C(1469598103934665603);
			engine_mux_hash_bytes(&client->subscribed_hash, state->payload,
			    state->payload_size);
			client->invalidation_pending = 0;
		}
		return;
	}
	if (type == ENGINE_MUX_GRID_DAMAGE_REQUEST) {
		if (payload_size != sizeof damage_request) {
			free(packet);
			if (engine_mux_send_error(client->fd, request_id,
			    "malformed-grid-request", "grid damage request has the wrong size") != 0)
				engine_mux_client_free(client);
			return;
		}
		memcpy(&damage_request, packet + sizeof header,
		    sizeof damage_request);
		free(packet);
		if (ntohl(damage_request.generation) != 1) {
			if (engine_mux_send_error(client->fd, request_id,
			    "stale-generation", "pane generation is not current") != 0)
				engine_mux_client_free(client);
			return;
		}
		pane = window_pane_find_by_id(ntohl(damage_request.pane_id));
		if (pane == NULL) {
			if (engine_mux_send_error(client->fd, request_id,
			    "pane-not-found", "pane does not exist") != 0)
				engine_mux_client_free(client);
			return;
		}
		if (engine_mux_send_grid_damage(client, pane, request_id,
		    engine_mux_be64_to_host(damage_request.grid_revision)) != 0) {
			if (errno != ESTALE) {
				engine_mux_client_free(client);
				return;
			}
			if (engine_mux_send_error(client->fd, request_id,
			    "grid-resync-required", "grid revision is stale; request a full grid") != 0)
				engine_mux_client_free(client);
		} else if (client->subscribed &&
		    client->subscribed_pane_id == pane->id) {
			struct engine_mux_grid_state *state =
			    engine_mux_grid_find(pane->id);
			client->subscribed_hash = UINT64_C(1469598103934665603);
			engine_mux_hash_bytes(&client->subscribed_hash, state->payload,
			    state->payload_size);
			client->invalidation_pending = 0;
		}
		return;
	}
	if (type == ENGINE_MUX_GRID_SUBSCRIBE_REQUEST) {
		struct engine_mux_grid_state *state;

		if (payload_size != sizeof damage_request) {
			free(packet);
			if (engine_mux_send_error(client->fd, request_id,
			    "malformed-grid-request", "grid subscription has the wrong size") != 0)
				engine_mux_client_free(client);
			return;
		}
		memcpy(&damage_request, packet + sizeof header,
		    sizeof damage_request);
		free(packet);
		if (ntohl(damage_request.generation) != 1) {
			if (engine_mux_send_error(client->fd, request_id,
			    "stale-generation", "pane generation is not current") != 0)
				engine_mux_client_free(client);
			return;
		}
		pane = window_pane_find_by_id(ntohl(damage_request.pane_id));
		state = engine_mux_grid_find(ntohl(damage_request.pane_id));
		if (pane == NULL || state == NULL || state->revision !=
		    engine_mux_be64_to_host(damage_request.grid_revision)) {
			if (engine_mux_send_error(client->fd, request_id,
			    "grid-resync-required", "grid subscription revision is stale") != 0)
				engine_mux_client_free(client);
			return;
		}
		client->subscribed_pane_id = pane->id;
		client->subscribed_generation = 1;
		client->subscribed_hash = UINT64_C(1469598103934665603);
		engine_mux_hash_bytes(&client->subscribed_hash, state->payload,
		    state->payload_size);
		client->subscribed = 1;
		client->invalidation_pending = 0;
		if (engine_mux_send_frame(client->fd, ENGINE_MUX_GRID_SUBSCRIBE_ACK,
		    request_id, engine_mux_revision, subscribe_ack,
		    strlen(subscribe_ack)) != 0)
			engine_mux_client_free(client);
		return;
	}
	if (type == ENGINE_MUX_SCROLLBACK_REQUEST) {
		if (payload_size != sizeof scrollback_request) {
			free(packet);
			if (engine_mux_send_error(client->fd, request_id,
			    "malformed-scrollback-request", "scrollback request has the wrong size") != 0)
				engine_mux_client_free(client);
			return;
		}
		memcpy(&scrollback_request, packet + sizeof header,
		    sizeof scrollback_request);
		free(packet);
		if (ntohl(scrollback_request.generation) != 1) {
			if (engine_mux_send_error(client->fd, request_id,
			    "stale-generation", "pane generation is not current") != 0)
				engine_mux_client_free(client);
			return;
		}
		pane = window_pane_find_by_id(ntohl(scrollback_request.pane_id));
		if (pane == NULL) {
			if (engine_mux_send_error(client->fd, request_id,
			    "pane-not-found", "pane does not exist") != 0)
				engine_mux_client_free(client);
			return;
		}
		scrollback = engine_mux_build_scrollback(pane,
		    ntohl(scrollback_request.start_row),
		    ntohl(scrollback_request.row_count), &scrollback_size);
		if (scrollback == NULL) {
			if (engine_mux_send_error(client->fd, request_id,
			    errno == ERANGE ? "scrollback-range" : "scrollback-too-large",
			    errno == ERANGE ? "scrollback range is outside pane history" :
			    "scrollback page exceeds the protocol payload limit") != 0)
				engine_mux_client_free(client);
			return;
		}
		if (engine_mux_send_frame(client->fd, ENGINE_MUX_SCROLLBACK,
		    request_id, engine_mux_revision, (char *)scrollback,
		    scrollback_size) != 0)
			engine_mux_client_free(client);
		free(scrollback);
		return;
	}
	free(packet);
	if (type == ENGINE_MUX_COMMAND_REQUEST &&
	    request_revision != engine_mux_revision) {
		if (engine_mux_send_error(client->fd, request_id,
		    "stale-revision", "request revision is not current; request a complete snapshot") != 0)
			engine_mux_client_free(client);
		return;
	}
	if (engine_mux_send_error(client->fd, request_id,
	    "unsupported-message", "message type is not implemented") != 0)
		engine_mux_client_free(client);
}

static void
engine_mux_accept(__unused int fd, __unused short events, __unused void *data)
{
	struct engine_mux_client *client;
	struct sockaddr_un address;
	socklen_t address_size, credentials_size;
	struct ucred credentials;
	int client_fd;

	address_size = sizeof address;
	client_fd = accept4(engine_mux_listener, (struct sockaddr *)&address,
	    &address_size, SOCK_NONBLOCK|SOCK_CLOEXEC);
	if (client_fd == -1)
		return;
	credentials_size = sizeof credentials;
	if (getsockopt(client_fd, SOL_SOCKET, SO_PEERCRED, &credentials,
	    &credentials_size) == -1 || credentials.uid != getuid()) {
		engine_mux_send_error(client_fd, 0, "peer-rejected",
		    "frontend peer uid does not own the mux server");
		close(client_fd);
		return;
	}
	client = xcalloc(1, sizeof *client);
	client->fd = client_fd;
	TAILQ_INSERT_TAIL(&engine_mux_clients, client, entry);
	event_set(&client->event, client_fd, EV_READ|EV_PERSIST,
	    engine_mux_client_event, client);
	event_add(&client->event, NULL);
}

int
engine_mux_frontend_init(void)
{
	const char *runtime_dir, *socket_name;
	char *state_dir;
	struct sockaddr_un address;
	mode_t old_mask;

	socket_name = strrchr(socket_path, '/');
	if (socket_name == NULL)
		socket_name = socket_path;
	else
		socket_name++;
	if (strcmp(socket_name, "engine-mux") != 0)
		return (0);
	runtime_dir = getenv("XDG_RUNTIME_DIR");
	if (runtime_dir == NULL || *runtime_dir == '\0')
		xasprintf(&state_dir, "/run/user/%lu/engineos",
		    (unsigned long)getuid());
	else
		xasprintf(&state_dir, "%s/engineos", runtime_dir);
	if (mkdir(state_dir, 0700) == -1 && errno != EEXIST) {
		free(state_dir);
		return (-1);
	}
	if (chmod(state_dir, 0700) == -1) {
		free(state_dir);
		return (-1);
	}
	xasprintf(&engine_mux_socket_path, "%s/mux.sock", state_dir);
	free(state_dir);
	if (strlen(engine_mux_socket_path) >= sizeof address.sun_path) {
		errno = ENAMETOOLONG;
		return (-1);
	}
	engine_mux_listener = socket(AF_UNIX,
	    SOCK_SEQPACKET|SOCK_NONBLOCK|SOCK_CLOEXEC, 0);
	if (engine_mux_listener == -1)
		return (-1);
	memset(&address, 0, sizeof address);
	address.sun_family = AF_UNIX;
	strlcpy(address.sun_path, engine_mux_socket_path,
	    sizeof address.sun_path);
	unlink(engine_mux_socket_path);
	old_mask = umask(0077);
	if (bind(engine_mux_listener, (struct sockaddr *)&address,
	    sizeof address) == -1 || listen(engine_mux_listener, 16) == -1) {
		umask(old_mask);
		engine_mux_frontend_free();
		return (-1);
	}
	umask(old_mask);
	engine_mux_frontend_sync();
	event_set(&engine_mux_accept_event, engine_mux_listener,
	    EV_READ|EV_PERSIST, engine_mux_accept, NULL);
	event_add(&engine_mux_accept_event, NULL);
	log_debug("engine mux frontend listening on %s", engine_mux_socket_path);
	return (0);
}

void
engine_mux_frontend_free(void)
{
	struct engine_mux_client *client, *next;
	struct engine_mux_grid_state *grid, *next_grid;

	TAILQ_FOREACH_SAFE(client, &engine_mux_clients, entry, next)
		engine_mux_client_free(client);
	TAILQ_FOREACH_SAFE(grid, &engine_mux_grids, entry, next_grid) {
		TAILQ_REMOVE(&engine_mux_grids, grid, entry);
		free(grid->payload);
		free(grid);
	}
	if (engine_mux_listener != -1) {
		event_del(&engine_mux_accept_event);
		close(engine_mux_listener);
		engine_mux_listener = -1;
	}
	if (engine_mux_socket_path != NULL) {
		unlink(engine_mux_socket_path);
		free(engine_mux_socket_path);
		engine_mux_socket_path = NULL;
	}
	free(engine_mux_snapshot);
	engine_mux_snapshot = NULL;
	engine_mux_snapshot_size = 0;
}
