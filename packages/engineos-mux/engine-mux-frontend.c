#include "tmux.h"

#include "engine-mux-frontend.h"
#include "engine-mux-protocol.h"

#include <arpa/inet.h>
#include <ctype.h>
#include <json-c/json.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

struct engine_mux_view {
	u_int id;
	int peer_fd;
	struct client *tmux_client;
	char *output_name;
	uint64_t ui_hash;
	int ui_subscribed;
	TAILQ_ENTRY(engine_mux_view) entry;
};
TAILQ_HEAD(engine_mux_view_list, engine_mux_view);

struct engine_mux_subscription {
	u_int pane_id;
	u_int generation;
	uint64_t hash;
	int invalidation_pending;
	TAILQ_ENTRY(engine_mux_subscription) entry;
};
TAILQ_HEAD(engine_mux_subscription_list, engine_mux_subscription);

struct engine_mux_client {
	int fd;
	struct event event;
	int state_invalidation_pending;
	struct engine_mux_view_list views;
	struct engine_mux_subscription_list subscriptions;
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
static u_int engine_mux_next_graphical_client_id;
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

static struct engine_mux_subscription *
engine_mux_subscription_find(struct engine_mux_client *client, u_int pane_id)
{
	struct engine_mux_subscription *subscription;

	TAILQ_FOREACH(subscription, &client->subscriptions, entry) {
		if (subscription->pane_id == pane_id)
			return (subscription);
	}
	return (NULL);
}
static void engine_mux_hash_bytes(uint64_t *, const void *, size_t);
static struct json_object *engine_mux_build_ui_model(struct engine_mux_view *);

static void
engine_mux_notify_state_clients(void)
{
	struct engine_mux_client *client, *next;

	TAILQ_FOREACH_SAFE(client, &engine_mux_clients, entry, next) {
		if (TAILQ_EMPTY(&client->views) || client->state_invalidation_pending)
			continue;
		if (engine_mux_send_frame(client->fd, ENGINE_MUX_STATE_INVALIDATED,
		    0, engine_mux_revision, NULL, 0) != 0) {
			if (errno != EAGAIN && errno != EWOULDBLOCK)
				engine_mux_client_free(client);
			continue;
		}
		client->state_invalidation_pending = 1;
	}
}

static uint64_t
engine_mux_ui_model_hash(struct json_object *model)
{
	const char *text = json_object_to_json_string_ext(model,
	    JSON_C_TO_STRING_PLAIN);
	uint64_t hash = UINT64_C(1469598103934665603);

	engine_mux_hash_bytes(&hash, text, strlen(text));
	return (hash);
}

static struct json_object *
engine_mux_parse_json(const u_char *payload, size_t payload_size)
{
	struct json_object *root;
	struct json_tokener *tokener;
	enum json_tokener_error json_error;
	size_t parse_end;
	char *copy;

	if (payload_size == 0 || memchr(payload, '\0', payload_size) != NULL)
		return (NULL);
	copy = xmalloc(payload_size + 1);
	memcpy(copy, payload, payload_size);
	copy[payload_size] = '\0';
	tokener = json_tokener_new();
	if (tokener == NULL) {
		free(copy);
		return (NULL);
	}
	root = json_tokener_parse_ex(tokener, copy, payload_size);
	json_error = json_tokener_get_error(tokener);
	parse_end = json_tokener_get_parse_end(tokener);
	while (parse_end < payload_size && isspace((u_char)copy[parse_end]))
		parse_end++;
	json_tokener_free(tokener);
	free(copy);
	if (json_error != json_tokener_success || parse_end != payload_size ||
	    root == NULL || !json_object_is_type(root, json_type_object)) {
		if (root != NULL)
			json_object_put(root);
		return (NULL);
	}
	return (root);
}

static int
engine_mux_json_u32(struct json_object *root, const char *name, u_int min,
    u_int max, u_int *value)
{
	struct json_object *object;
	int64_t parsed;

	if (!json_object_object_get_ex(root, name, &object) ||
	    !json_object_is_type(object, json_type_int))
		return (-1);
	parsed = json_object_get_int64(object);
	if (parsed < min || (uint64_t)parsed > max)
		return (-1);
	*value = (u_int)parsed;
	return (0);
}

static const char *
engine_mux_json_string_value(struct json_object *root, const char *name,
    size_t max_length)
{
	struct json_object *object;
	const char *value;
	size_t length;

	if (!json_object_object_get_ex(root, name, &object) ||
	    !json_object_is_type(object, json_type_string))
		return (NULL);
	value = json_object_get_string(object);
	length = json_object_get_string_len(object);
	if (value == NULL || length == 0 || length > max_length ||
	    memchr(value, '\0', length) != NULL)
		return (NULL);
	return (value);
}

static struct engine_mux_view *
engine_mux_view_find(struct engine_mux_client *client, u_int id)
{
	struct engine_mux_view *view;

	TAILQ_FOREACH(view, &client->views, entry) {
		if (view->id == id)
			return (view);
	}
	return (NULL);
}

static int
engine_mux_presentation_dispatch(struct json_object *root, int map,
    char **cause)
{
	struct window_pane *pane;
	const char *schema, *pane_id, *role = NULL;
	u_int generation, pid, surface_id;

	schema = engine_mux_json_string_value(root, "schema", 64);
	pane_id = engine_mux_json_string_value(root, "pane_id", 32);
	if (schema == NULL || pane_id == NULL ||
	    strcmp(schema, map ? "engine-mux/presentation-map-v1" :
	    "engine-mux/presentation-unmap-v1") != 0 ||
	    engine_mux_json_u32(root, "generation", 1, UINT32_MAX,
	    &generation) != 0 ||
	    engine_mux_json_u32(root, "pid", 1, INT32_MAX, &pid) != 0 ||
	    engine_mux_json_u32(root, "surface_id", 1, UINT32_MAX,
	    &surface_id) != 0) {
		*cause = xstrdup("presentation surface request is invalid");
		return (-1);
	}
	if (map && (role = engine_mux_json_string_value(root, "role", 16)) == NULL) {
		*cause = xstrdup("presentation surface role is missing");
		return (-1);
	}
	pane = window_pane_find_by_id_str(pane_id);
	if (pane == NULL || pane->engine_generation != generation) {
		*cause = xstrdup("presentation pane generation is not current");
		return (-1);
	}
	if (map)
		return (engine_pane_surface_map(pane, (pid_t)pid, surface_id,
		    role, cause));
	return (engine_pane_surface_unmap(pane, (pid_t)pid, surface_id, cause));
}

static void
engine_mux_view_focus(struct engine_mux_view *focused)
{
	struct engine_mux_client *client;
	struct engine_mux_view *view;
	struct client *tmux_client;

	TAILQ_FOREACH(client, &engine_mux_clients, entry) {
		TAILQ_FOREACH(view, &client->views, entry) {
			tmux_client = view->tmux_client;
			if (tmux_client == NULL ||
			    (tmux_client->flags & CLIENT_DEAD))
				continue;
			if (view == focused) {
				tmux_client->flags |= CLIENT_FOCUSED;
				tmux_client->flags &= ~CLIENT_IGNORESIZE;
			} else {
				tmux_client->flags &= ~CLIENT_FOCUSED;
				tmux_client->flags |= CLIENT_IGNORESIZE;
			}
		}
	}
	tmux_client = focused->tmux_client;
	if (tmux_client->session != NULL) {
		tmux_client->session->curw->window->latest = tmux_client;
		window_update_focus(tmux_client->session->curw->window);
		notify_client("client-active", tmux_client);
	}
	recalculate_sizes();
}

static void
engine_mux_view_free(struct engine_mux_client *client,
    struct engine_mux_view *view)
{
	struct engine_mux_client *other_client;
	struct engine_mux_view *other_view;
	int was_focused = view->tmux_client != NULL &&
	    (view->tmux_client->flags & CLIENT_FOCUSED) &&
	    (~view->tmux_client->flags & CLIENT_IGNORESIZE);

	TAILQ_REMOVE(&client->views, view, entry);
	if (view->tmux_client != NULL &&
	    (~view->tmux_client->flags & CLIENT_DEAD)) {
		server_client_set_session(view->tmux_client, NULL);
		server_client_lost(view->tmux_client);
	}
	if (view->peer_fd != -1)
		close(view->peer_fd);
	free(view->output_name);
	free(view);
	if (!was_focused)
		return;
	TAILQ_FOREACH(other_client, &engine_mux_clients, entry) {
		TAILQ_FOREACH(other_view, &other_client->views, entry) {
			if (other_view->tmux_client == NULL ||
			    other_view->tmux_client->session == NULL ||
			    (other_view->tmux_client->flags & CLIENT_DEAD))
				continue;
			engine_mux_view_focus(other_view);
			return;
		}
	}
}

static int
engine_mux_view_register(struct engine_mux_client *client,
    struct json_object *root, char **cause)
{
	struct engine_mux_view *view;
	struct session *session;
	struct client *tmux_client;
	struct client *previous_latest;
	char *client_name;
	const char *schema, *session_id, *output;
	struct json_object *focused_object;
	u_int id, columns, rows, pixel_width, pixel_height, scale_milli;
	int pair[2], focused;

	schema = engine_mux_json_string_value(root, "schema", 64);
	session_id = engine_mux_json_string_value(root, "session_id", 32);
	output = engine_mux_json_string_value(root, "output", 128);
	if (schema == NULL || strcmp(schema, "engine-mux/view-register-v1") != 0 ||
	    session_id == NULL || output == NULL ||
	    engine_mux_json_u32(root, "view_id", 1, UINT32_MAX, &id) != 0 ||
	    engine_mux_json_u32(root, "columns", WINDOW_MINIMUM, WINDOW_MAXIMUM,
	    &columns) != 0 ||
	    engine_mux_json_u32(root, "rows", WINDOW_MINIMUM, WINDOW_MAXIMUM,
	    &rows) != 0 ||
	    engine_mux_json_u32(root, "pixel_width", 1, 100000, &pixel_width) != 0 ||
	    engine_mux_json_u32(root, "pixel_height", 1, 100000, &pixel_height) != 0 ||
	    engine_mux_json_u32(root, "scale_milli", 100, 10000, &scale_milli) != 0 ||
	    !json_object_object_get_ex(root, "focused", &focused_object) ||
	    !json_object_is_type(focused_object, json_type_boolean)) {
		*cause = xstrdup("graphical view registration is invalid");
		return (-1);
	}
	(void)scale_milli;
	focused = json_object_get_boolean(focused_object);
	if (engine_mux_view_find(client, id) != NULL) {
		*cause = xstrdup("graphical view identifier is already registered");
		return (-1);
	}
	session = session_find_by_id_str(session_id);
	if (session == NULL) {
		*cause = xstrdup("graphical view session does not exist");
		return (-1);
	}
	if (socketpair(AF_UNIX, SOCK_STREAM|SOCK_CLOEXEC, 0, pair) != 0) {
		xasprintf(cause, "graphical client socketpair: %s", strerror(errno));
		return (-1);
	}
	view = xcalloc(1, sizeof *view);
	view->id = id;
	view->peer_fd = pair[1];
	view->output_name = xstrdup(output);
	tmux_client = server_client_create(pair[0]);
	view->tmux_client = tmux_client;
	xasprintf(&client_name, "engineos-view-%u",
	    ++engine_mux_next_graphical_client_id);
	tmux_client->name = client_name;
	tmux_client->ttyname = xstrdup(output);
	tmux_client->term_name = xstrdup("engineos-graphical");
	if (session->cwd != NULL)
		tmux_client->cwd = xstrdup(session->cwd);
	tmux_client->tty.client = tmux_client;
	tmux_client->tty.sx = columns;
	tmux_client->tty.sy = rows;
	tmux_client->tty.xpixel = pixel_width / columns;
	tmux_client->tty.ypixel = pixel_height / rows;
	tmux_client->flags |= CLIENT_ATTACHED|CLIENT_IDENTIFIED|CLIENT_UTF8|
	    CLIENT_GRAPHICAL|CLIENT_SIZECHANGED;
	if (focused)
		tmux_client->flags |= CLIENT_FOCUSED;
	else {
		tmux_client->flags &= ~CLIENT_FOCUSED;
		tmux_client->flags |= CLIENT_IGNORESIZE;
	}
	previous_latest = session->curw->window->latest;
	TAILQ_INSERT_TAIL(&client->views, view, entry);
	server_client_set_session(tmux_client, session);
	if (focused)
		engine_mux_view_focus(view);
	else {
		tmux_client->flags &= ~CLIENT_FOCUSED;
		session->curw->window->latest = previous_latest;
	}
	server_client_set_key_table(tmux_client, NULL);
	recalculate_sizes();
	return (0);
}

static int
engine_mux_key_dispatch(struct engine_mux_client *client,
    struct json_object *root, char **cause)
{
	struct engine_mux_view *view;
	struct window_pane *pane;
	struct key_event *event;
	const char *schema, *pane_id, *key_name;
	key_code key;
	u_int view_id, generation;

	schema = engine_mux_json_string_value(root, "schema", 64);
	pane_id = engine_mux_json_string_value(root, "pane_id", 32);
	key_name = engine_mux_json_string_value(root, "key", 64);
	if (schema == NULL || strcmp(schema, "engine-mux/key-v1") != 0 ||
	    pane_id == NULL || key_name == NULL ||
	    engine_mux_json_u32(root, "view_id", 1, UINT32_MAX, &view_id) != 0 ||
	    engine_mux_json_u32(root, "generation", 1, UINT32_MAX,
	    &generation) != 0) {
		*cause = xstrdup("graphical key request is invalid");
		return (-1);
	}
	view = engine_mux_view_find(client, view_id);
	pane = window_pane_find_by_id_str(pane_id);
	if (view == NULL || pane == NULL || generation != 1 ||
	    view->tmux_client->session == NULL ||
	    view->tmux_client->session->curw->window->active != pane) {
		*cause = xstrdup("graphical key target is not the active registered pane");
		return (-1);
	}
	key = key_string_lookup_string(key_name);
	if (key == KEYC_UNKNOWN || key == KEYC_NONE || KEYC_IS_MOUSE(key)) {
		*cause = xstrdup("graphical key name is unsupported");
		return (-1);
	}
	event = xcalloc(1, sizeof *event);
	event->key = key|KEYC_SENT;
	if (!server_client_handle_key(view->tmux_client, event)) {
		free(event);
		*cause = xstrdup("graphical tmux client is not accepting input");
		return (-1);
	}
	return (0);
}

static int
engine_mux_mouse_button(const char *name, u_int *button)
{
	if (strcmp(name, "none") == 0)
		*button = 3;
	else if (strcmp(name, "left") == 0)
		*button = MOUSE_BUTTON_1;
	else if (strcmp(name, "middle") == 0)
		*button = MOUSE_BUTTON_2;
	else if (strcmp(name, "right") == 0)
		*button = MOUSE_BUTTON_3;
	else if (strcmp(name, "wheel-up") == 0)
		*button = MOUSE_WHEEL_UP;
	else if (strcmp(name, "wheel-down") == 0)
		*button = MOUSE_WHEEL_DOWN;
	else
		return (-1);
	return (0);
}

static int
engine_mux_mouse_dispatch(struct engine_mux_client *client,
    struct json_object *root, char **cause)
{
	struct engine_mux_view *view;
	struct client *tmux_client;
	struct key_event *event;
	struct json_object *ui_model;
	const char *schema, *type, *button_name;
	u_int view_id, x, y, button, modifiers, encoded_button;

	schema = engine_mux_json_string_value(root, "schema", 64);
	type = engine_mux_json_string_value(root, "event", 16);
	button_name = engine_mux_json_string_value(root, "button", 16);
	if (schema == NULL || strcmp(schema, "engine-mux/mouse-v1") != 0 ||
	    type == NULL || button_name == NULL ||
	    engine_mux_json_u32(root, "view_id", 1, UINT32_MAX, &view_id) != 0 ||
	    engine_mux_json_u32(root, "x", 0, WINDOW_MAXIMUM, &x) != 0 ||
	    engine_mux_json_u32(root, "y", 0, WINDOW_MAXIMUM, &y) != 0 ||
	    engine_mux_json_u32(root, "modifiers", 0, 7, &modifiers) != 0 ||
	    engine_mux_mouse_button(button_name, &button) != 0) {
		*cause = xstrdup("graphical mouse request is invalid");
		return (-1);
	}
	view = engine_mux_view_find(client, view_id);
	if (view == NULL || (tmux_client = view->tmux_client) == NULL ||
	    tmux_client->session == NULL || (tmux_client->flags & CLIENT_DEAD) ||
	    (~tmux_client->flags & CLIENT_FOCUSED) ||
	    (tmux_client->flags & CLIENT_IGNORESIZE) ||
	    x >= tmux_client->tty.sx || y >= tmux_client->tty.sy) {
		*cause = xstrdup("graphical mouse target is not an attached client cell");
		return (-1);
	}
	encoded_button = button;
	tmux_client->tty.oox = 0;
	tmux_client->tty.ooy = 0;
	tmux_client->tty.osx = tmux_client->session->curw->window->sx;
	tmux_client->tty.osy = tmux_client->session->curw->window->sy;
	ui_model = engine_mux_build_ui_model(view);
	if (ui_model == NULL) {
		*cause = xstrdup("graphical mouse UI state could not be rendered");
		return (-1);
	}
	json_object_put(ui_model);
	if (modifiers & 1)
		encoded_button |= MOUSE_MASK_SHIFT;
	if (modifiers & 2)
		encoded_button |= MOUSE_MASK_META;
	if (modifiers & 4)
		encoded_button |= MOUSE_MASK_CTRL;

	event = xcalloc(1, sizeof *event);
	event->key = KEYC_MOUSE;
	event->m.lx = tmux_client->tty.mouse_last_x;
	event->m.ly = tmux_client->tty.mouse_last_y;
	event->m.lb = tmux_client->tty.mouse_last_b;
	event->m.x = x;
	event->m.y = y;
	event->m.sgr_type = 'M';
	event->m.sgr_b = encoded_button;
	event->m.b = encoded_button;
	if (strcmp(type, "motion") == 0) {
		event->m.sgr_b |= MOUSE_MASK_DRAG;
		event->m.b = event->m.sgr_b;
	} else if (strcmp(type, "release") == 0) {
		if (button == 3 || MOUSE_WHEEL(button)) {
			free(event);
			*cause = xstrdup("graphical mouse release button is invalid");
			return (-1);
		}
		event->m.sgr_type = 'm';
		event->m.b = 3;
	} else if (strcmp(type, "press") == 0) {
		if (button == 3 || MOUSE_WHEEL(button)) {
			free(event);
			*cause = xstrdup("graphical mouse press button is invalid");
			return (-1);
		}
	} else if (strcmp(type, "wheel") == 0) {
		if (!MOUSE_WHEEL(button)) {
			free(event);
			*cause = xstrdup("graphical mouse wheel button is invalid");
			return (-1);
		}
	} else {
		free(event);
		*cause = xstrdup("graphical mouse event type is invalid");
		return (-1);
	}
	tmux_client->tty.mouse_last_x = x;
	tmux_client->tty.mouse_last_y = y;
	tmux_client->tty.mouse_last_b = event->m.b;
	if (!server_client_handle_key(tmux_client, event))
		free(event);
	return (0);
}

static int
engine_mux_status_style_equal(const struct grid_cell *left,
    const struct grid_cell *right)
{
	return (left->attr == right->attr && left->fg == right->fg &&
	    left->bg == right->bg && left->us == right->us &&
	    left->link == right->link);
}

static void
engine_mux_status_add_span(struct json_object *spans, u_int start, u_int end,
    const struct grid_cell *cell)
{
	struct json_object *span = json_object_new_object();

	json_object_object_add(span, "start", json_object_new_int64(start));
	json_object_object_add(span, "end", json_object_new_int64(end));
	json_object_object_add(span, "attributes",
	    json_object_new_int64(cell->attr));
	json_object_object_add(span, "foreground",
	    json_object_new_int64(cell->fg));
	json_object_object_add(span, "background",
	    json_object_new_int64(cell->bg));
	json_object_object_add(span, "underline_colour",
	    json_object_new_int64(cell->us));
	json_object_object_add(span, "hyperlink",
	    json_object_new_int64(cell->link));
	json_object_array_add(spans, span);
}

static struct json_object *
engine_mux_screen_rows(struct screen *screen, u_int rows)
{
	struct json_object *result = json_object_new_array();
	struct grid_cell cell, style;
	struct evbuffer *text;
	u_int x, y, columns = screen_size_x(screen), style_start;

	for (y = 0; y < rows; y++) {
		struct json_object *row = json_object_new_object();
		struct json_object *spans = json_object_new_array();
		text = evbuffer_new();
		style_start = 0;
		memset(&style, 0, sizeof style);
		for (x = 0; x < columns; x++) {
			grid_view_get_cell(screen->grid, x, y, &cell);
			if (x == 0)
				memcpy(&style, &cell, sizeof style);
			else if (!engine_mux_status_style_equal(&style, &cell)) {
				engine_mux_status_add_span(spans, style_start, x, &style);
				memcpy(&style, &cell, sizeof style);
				style_start = x;
			}
			if (cell.flags & GRID_FLAG_PADDING)
				continue;
			if (cell.data.have == 0)
				evbuffer_add(text, " ", 1);
			else
				evbuffer_add(text, cell.data.data, cell.data.have);
		}
		if (columns != 0)
			engine_mux_status_add_span(spans, style_start, columns, &style);
		json_object_object_add(row, "text", json_object_new_string_len(
		    (const char *)EVBUFFER_DATA(text), EVBUFFER_LENGTH(text)));
		json_object_object_add(row, "spans", spans);
		json_object_array_add(result, row);
		evbuffer_free(text);
	}
	return (result);
}

static struct json_object *
engine_mux_build_ui_model(struct engine_mux_view *view)
{
	struct client *client = view->tmux_client;
	struct status_line *status = &client->status;
	struct screen *screen, *menu_screen = NULL;
	struct menu *menu = NULL;
	struct json_object *root, *status_object, *prompt, *message, *menu_object;
	struct json_object *items;
	char *prompt_input;
	const char *mode = "status";
	u_int lines, rendered_lines, px = 0, py = 0, index;
	int choice = -1, menu_active, status_y;

	lines = status_line_size(client);
	if (client->prompt_string != NULL) {
		status_prompt_redraw(client);
		mode = "prompt";
	} else if (client->message_string != NULL) {
		status_message_redraw(client);
		mode = "message";
	} else
		status_redraw(client);
	screen = status->active;
	rendered_lines = lines;
	if (rendered_lines == 0 &&
	    (client->prompt_string != NULL || client->message_string != NULL))
		rendered_lines = 1;
	if (rendered_lines > screen_size_y(screen))
		rendered_lines = screen_size_y(screen);
	status_y = status_at_line(client);
	if (status_y < 0 && rendered_lines != 0)
		status_y = client->tty.sy - rendered_lines;

	root = json_object_new_object();
	json_object_object_add(root, "schema",
	    json_object_new_string("engine-mux/ui-model-v1"));
	json_object_object_add(root, "view_id", json_object_new_int64(view->id));
	json_object_object_add(root, "columns",
	    json_object_new_int64(client->tty.sx));
	json_object_object_add(root, "rows", json_object_new_int64(client->tty.sy));
	status_object = json_object_new_object();
	json_object_object_add(status_object, "enabled",
	    json_object_new_boolean(lines != 0));
	json_object_object_add(status_object, "line_count",
	    json_object_new_int64(lines));
	json_object_object_add(status_object, "rendered_line_count",
	    json_object_new_int64(rendered_lines));
	json_object_object_add(status_object, "y", json_object_new_int64(status_y));
	json_object_object_add(status_object, "mode", json_object_new_string(mode));
	json_object_object_add(status_object, "rows",
	    engine_mux_screen_rows(screen, rendered_lines));
	json_object_object_add(root, "status", status_object);

	prompt = json_object_new_object();
	json_object_object_add(prompt, "active",
	    json_object_new_boolean(client->prompt_string != NULL));
	if (client->prompt_string != NULL) {
		prompt_input = utf8_tocstr(client->prompt_buffer);
		json_object_object_add(prompt, "label",
		    json_object_new_string(client->prompt_string));
		json_object_object_add(prompt, "input",
		    json_object_new_string(prompt_input));
		json_object_object_add(prompt, "cursor",
		    json_object_new_int64(client->prompt_index));
		json_object_object_add(prompt, "screen_cursor_x",
		    json_object_new_int(client->prompt_cursor));
		json_object_object_add(prompt, "type",
		    json_object_new_int(client->prompt_type));
		json_object_object_add(prompt, "flags",
		    json_object_new_int(client->prompt_flags));
		free(prompt_input);
	}
	json_object_object_add(root, "prompt", prompt);

	message = json_object_new_object();
	json_object_object_add(message, "active",
	    json_object_new_boolean(client->message_string != NULL));
	if (client->message_string != NULL)
		json_object_object_add(message, "text",
		    json_object_new_string(client->message_string));
	json_object_object_add(root, "message", message);

	menu_object = json_object_new_object();
	menu_active = menu_get_model(client, &menu, &choice, &px, &py,
	    &menu_screen);
	json_object_object_add(menu_object, "active",
	    json_object_new_boolean(menu_active));
	if (menu != NULL) {
		json_object_object_add(menu_object, "title",
		    json_object_new_string(menu->title));
		json_object_object_add(menu_object, "x", json_object_new_int64(px));
		json_object_object_add(menu_object, "y", json_object_new_int64(py));
		json_object_object_add(menu_object, "width",
		    json_object_new_int64(menu->width + 4));
		json_object_object_add(menu_object, "height",
		    json_object_new_int64(menu->count + 2));
		json_object_object_add(menu_object, "selected",
		    json_object_new_int(choice));
		json_object_object_add(menu_object, "rows",
		    engine_mux_screen_rows(menu_screen, screen_size_y(menu_screen)));
		items = json_object_new_array();
		for (index = 0; index < menu->count; index++) {
			struct menu_item *item = &menu->items[index];
			struct json_object *item_object = json_object_new_object();
			json_object_object_add(item_object, "separator",
			    json_object_new_boolean(item->name == NULL));
			if (item->name != NULL)
				json_object_object_add(item_object, "name",
				    json_object_new_string(item->name));
			if (item->key != KEYC_NONE)
				json_object_object_add(item_object, "key",
				    json_object_new_string(key_string_lookup_key(item->key, 0)));
			if (item->command != NULL)
				json_object_object_add(item_object, "command",
				    json_object_new_string(item->command));
			json_object_array_add(items, item_object);
		}
		json_object_object_add(menu_object, "items", items);
	}
	json_object_object_add(root, "menu", menu_object);
	return (root);
}

static void
engine_mux_notify_ui_clients(void)
{
	struct engine_mux_client *client, *next;
	struct engine_mux_view *view;
	struct engine_mux_ui_invalidation invalidated;
	struct json_object *model;
	uint64_t hash;
	int failed;

	TAILQ_FOREACH_SAFE(client, &engine_mux_clients, entry, next) {
		failed = 0;
		TAILQ_FOREACH(view, &client->views, entry) {
			if (!view->ui_subscribed)
				continue;
			model = engine_mux_build_ui_model(view);
			hash = engine_mux_ui_model_hash(model);
			json_object_put(model);
			if (hash == view->ui_hash)
				continue;
			invalidated.view_id = htonl(view->id);
			if (engine_mux_send_frame(client->fd,
			    ENGINE_MUX_UI_INVALIDATED, 0, engine_mux_revision,
			    (char *)&invalidated, sizeof invalidated) != 0) {
				if (errno != EAGAIN && errno != EWOULDBLOCK) {
					engine_mux_client_free(client);
					failed = 1;
				}
				break;
			}
			view->ui_hash = hash;
		}
		if (failed)
			continue;
	}
}

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
	struct options_entry *prefix_option, *prefix2_option;
	char *layout, *command;
	char *prefix_name, *prefix2_name;
	char *result;
	int first = 1, pane_active, pane_visible, window_active, copy_mode;
	uint64_t hash = UINT64_C(1469598103934665603);

	buffer = evbuffer_new();
	if (buffer == NULL)
		fatalx("engine mux snapshot allocation failed");
	evbuffer_add_printf(buffer,
	    "{\"schema\":\"engine-mux/snapshot-v1\",\"revision\":%llu,\"panes\":[",
	    (unsigned long long)revision);

	RB_FOREACH(session, sessions, &sessions) {
		prefix_option = options_get(session->options, "prefix");
		prefix2_option = options_get(session->options, "prefix2");
		prefix_name = options_to_string(prefix_option, -1, 0);
		prefix2_name = options_to_string(prefix2_option, -1, 0);
		RB_FOREACH(winlink, winlinks, &session->windows) {
			window = winlink->window;
			window_active = session->curw == winlink;
			layout = layout_dump(window->layout_root);
			TAILQ_FOREACH(pane, &window->panes, entry) {
				pane_active = window->active == pane;
				pane_visible = window_pane_visible(pane);
				copy_mode = pane->screen != &pane->base;
				command = engine_mux_current_command(pane);
				if (!first)
					evbuffer_add(buffer, ",", 1);
				first = 0;
				evbuffer_add_printf(buffer,
				    "{\"session_id\":\"$%u\",\"session_name\":",
				    session->id);
				engine_mux_json_string(buffer, session->name);
				evbuffer_add(buffer, ",\"prefix\":", 10);
				engine_mux_json_string(buffer, prefix_name);
				evbuffer_add(buffer, ",\"prefix2\":", 11);
				engine_mux_json_string(buffer, prefix2_name);
				evbuffer_add_printf(buffer,
				    ",\"window_id\":\"@%u\",\"window_index\":%d,\"window_active\":%s,\"window_layout\":",
				    window->id, winlink->idx,
				    window_active ? "true" : "false");
				engine_mux_json_string(buffer, layout);
				evbuffer_add_printf(buffer,
				    ",\"pane_id\":\"%%%u\",\"generation\":%u,\"pid\":%lld,\"tty\":",
				    pane->id, pane->engine_generation,
				    (long long)pane->pid);
				engine_mux_json_string(buffer, pane->tty);
				evbuffer_add_printf(buffer,
				    ",\"left\":%u,\"top\":%u,\"columns\":%u,\"rows\":%u,\"history_rows\":%u,\"history_scrolled\":%u,\"copy_mode\":%s,\"active\":%s,\"visible\":%s,\"command\":",
				    pane->xoff, pane->yoff, pane->sx, pane->sy,
				    pane->base.grid->hsize, pane->base.grid->hscrolled,
				    copy_mode ? "true" : "false",
				    pane_active ? "true" : "false",
				    pane_visible ? "true" : "false");
				engine_mux_json_string(buffer, command);
				evbuffer_add(buffer, ",\"title\":", 9);
				engine_mux_json_string(buffer, pane->base.title);
				evbuffer_add(buffer, ",\"presentation\":", 16);
				engine_mux_json_string(buffer,
				    engine_pane_presentation_name(pane));
				evbuffer_add(buffer, ",\"view_mode\":", 13);
				engine_mux_json_string(buffer,
				    engine_pane_view_mode_name(pane));
				evbuffer_add(buffer, ",\"process_scope\":", 17);
				engine_mux_json_string(buffer, pane->engine_scope);
				evbuffer_add(buffer, ",\"app_command\":", 15);
				engine_mux_json_string(buffer, pane->engine_command);
				evbuffer_add_printf(buffer,
				    ",\"app_pid\":%lld,\"mapped\":%s,\"surface_tabs\":%u,\"active_surface_id\":%u}",
				    (long long)pane->engine_app_pgrp,
				    pane->engine_mapped ? "true" : "false",
				    pane->engine_surface_count,
				    pane->engine_active_surface_id);

				engine_mux_hash_bytes(&hash, &session->id,
				    sizeof session->id);
				engine_mux_hash_string(&hash, session->name);
				engine_mux_hash_string(&hash, prefix_name);
				engine_mux_hash_string(&hash, prefix2_name);
				engine_mux_hash_bytes(&hash, &window->id,
				    sizeof window->id);
				engine_mux_hash_bytes(&hash, &winlink->idx,
				    sizeof winlink->idx);
				engine_mux_hash_bytes(&hash, &window_active,
				    sizeof window_active);
				engine_mux_hash_string(&hash, layout);
				engine_mux_hash_bytes(&hash, &pane->id,
				    sizeof pane->id);
				engine_mux_hash_bytes(&hash, &pane->engine_generation,
				    sizeof pane->engine_generation);
				engine_mux_hash_bytes(&hash, &pane->pid,
				    sizeof pane->pid);
				engine_mux_hash_string(&hash, pane->tty);
				engine_mux_hash_bytes(&hash, &pane->sx,
				    sizeof pane->sx);
				engine_mux_hash_bytes(&hash, &pane->sy,
				    sizeof pane->sy);
				engine_mux_hash_bytes(&hash, &pane->xoff,
				    sizeof pane->xoff);
				engine_mux_hash_bytes(&hash, &pane->yoff,
				    sizeof pane->yoff);
				engine_mux_hash_bytes(&hash, &pane->base.grid->hsize,
				    sizeof pane->base.grid->hsize);
				engine_mux_hash_bytes(&hash, &pane->base.grid->hscrolled,
				    sizeof pane->base.grid->hscrolled);
				engine_mux_hash_bytes(&hash, &copy_mode,
				    sizeof copy_mode);
				engine_mux_hash_bytes(&hash, &pane_active,
				    sizeof pane_active);
				engine_mux_hash_bytes(&hash, &pane_visible,
				    sizeof pane_visible);
				engine_mux_hash_string(&hash, command);
				engine_mux_hash_string(&hash, pane->base.title);
				engine_mux_hash_bytes(&hash, &pane->engine_presentation,
				    sizeof pane->engine_presentation);
				engine_mux_hash_bytes(&hash, &pane->engine_view_mode,
				    sizeof pane->engine_view_mode);
				engine_mux_hash_string(&hash, pane->engine_scope);
				engine_mux_hash_string(&hash, pane->engine_command);
				engine_mux_hash_bytes(&hash, &pane->engine_app_pgrp,
				    sizeof pane->engine_app_pgrp);
				engine_mux_hash_bytes(&hash, &pane->engine_mapped,
				    sizeof pane->engine_mapped);
				engine_mux_hash_bytes(&hash, &pane->engine_surface_count,
				    sizeof pane->engine_surface_count);
				engine_mux_hash_bytes(&hash, &pane->engine_active_surface_id,
				    sizeof pane->engine_active_surface_id);
				free(command);
			}
			free(layout);
		}
		free(prefix_name);
		free(prefix2_name);
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
	if (screen->mode & MODE_KCURSOR)
		flags |= ENGINE_MUX_GRID_CURSOR_KEYS_APPLICATION;
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
	struct engine_mux_subscription *subscription, *subscription_next;
	struct engine_mux_grid_request invalidated;
	struct window_pane *pane;
	u_char *payload;
	size_t payload_size;
	uint64_t hash;

	TAILQ_FOREACH_SAFE(client, &engine_mux_clients, entry, next) {
		TAILQ_FOREACH_SAFE(subscription, &client->subscriptions, entry,
		    subscription_next) {
			if (subscription->invalidation_pending)
				continue;
			pane = window_pane_find_by_id(subscription->pane_id);
			if (pane == NULL) {
				TAILQ_REMOVE(&client->subscriptions, subscription, entry);
				free(subscription);
				continue;
			}
			payload = engine_mux_build_grid(pane, &payload_size);
			if (payload == NULL)
				continue;
			hash = UINT64_C(1469598103934665603);
			engine_mux_hash_bytes(&hash, payload, payload_size);
			free(payload);
			if (hash == subscription->hash)
				continue;
			invalidated.pane_id = htonl(subscription->pane_id);
			invalidated.generation = htonl(subscription->generation);
			if (engine_mux_send_frame(client->fd,
			    ENGINE_MUX_GRID_INVALIDATED, 0, engine_mux_revision,
			    (char *)&invalidated, sizeof invalidated) != 0) {
				if (errno != EAGAIN && errno != EWOULDBLOCK) {
					engine_mux_client_free(client);
					break;
				}
				continue;
			}
			subscription->hash = hash;
			subscription->invalidation_pending = 1;
		}
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
	engine_pane_sync_all();

	candidate = engine_mux_build_snapshot(engine_mux_revision,
	    &content_hash, &candidate_size);
	if (engine_mux_snapshot != NULL &&
	    content_hash == engine_mux_snapshot_hash) {
		free(candidate);
		engine_mux_notify_grid_clients();
		engine_mux_notify_ui_clients();
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
	engine_mux_notify_ui_clients();
	engine_mux_notify_state_clients();
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
	struct engine_mux_view *view, *next;
	struct engine_mux_subscription *subscription, *subscription_next;

	TAILQ_FOREACH_SAFE(view, &client->views, entry, next)
		engine_mux_view_free(client, view);
	TAILQ_FOREACH_SAFE(subscription, &client->subscriptions, entry,
	    subscription_next) {
		TAILQ_REMOVE(&client->subscriptions, subscription, entry);
		free(subscription);
	}
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
	struct engine_mux_input_header input_header;
	struct window_pane *pane;
	u_char *scrollback;
	size_t scrollback_size;
	const char *hello =
	    "{\"schema\":\"engine-mux/hello-v1\",\"server\":\"engine-mux\","
	    "\"tmux_baseline\":\"3.6b\",\"capabilities\":[\"layout-snapshot\",\"terminal-grid-v1\",\"grid-subscribe-v1\",\"pane-input-v1\",\"graphical-view-v1\",\"tmux-key-v1\",\"view-focus-v1\",\"ui-model-v1\",\"ui-invalidate-v1\",\"tmux-mouse-v1\",\"pane-presentation-v1\",\"presentation-resolve-v1\",\"pane-surface-select-v1\"]}";
	const char *subscribe_ack =
	    "{\"schema\":\"engine-mux/grid-subscribe-v1\",\"subscribed\":true}";
	const char *input_ack =
	    "{\"schema\":\"engine-mux/pane-input-v1\",\"accepted\":true}";
	const char *view_ack =
	    "{\"schema\":\"engine-mux/view-register-v1\",\"registered\":true}";
	const char *view_unregister_ack =
	    "{\"schema\":\"engine-mux/view-unregister-v1\",\"unregistered\":true}";
	const char *view_focus_ack =
	    "{\"schema\":\"engine-mux/view-focus-v1\",\"focused\":true}";
	const char *key_ack =
	    "{\"schema\":\"engine-mux/key-v1\",\"queued\":true}";
	const char *mouse_ack =
	    "{\"schema\":\"engine-mux/mouse-v1\",\"queued\":true}";
	const char *presentation_map_ack =
	    "{\"schema\":\"engine-mux/presentation-map-v1\",\"mapped\":true}";
	const char *presentation_unmap_ack =
	    "{\"schema\":\"engine-mux/presentation-unmap-v1\",\"unmapped\":true}";

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
		client->state_invalidation_pending = 0;
		engine_mux_frontend_sync();
		if (engine_mux_send_frame(client->fd, ENGINE_MUX_SNAPSHOT,
		    request_id, engine_mux_revision, engine_mux_snapshot,
		    engine_mux_snapshot_size) != 0)
			engine_mux_client_free(client);
		return;
	}
	if (type == ENGINE_MUX_PRESENTATION_RESOLVE_REQUEST) {
		struct json_object *root, *response;
		struct window_pane *resolved;
		const char *schema, *response_text;
		char *cause = NULL, pane_id[32];
		u_int pid;

		root = engine_mux_parse_json(packet + sizeof header, payload_size);
		free(packet);
		if (root == NULL) {
			if (engine_mux_send_error(client->fd, request_id,
			    "malformed-json", "presentation resolve request is not valid JSON") != 0)
				engine_mux_client_free(client);
			return;
		}
		schema = engine_mux_json_string_value(root, "schema", 64);
		if (schema == NULL ||
		    strcmp(schema, "engine-mux/presentation-resolve-v1") != 0 ||
		    engine_mux_json_u32(root, "pid", 1, INT32_MAX, &pid) != 0) {
			json_object_put(root);
			if (engine_mux_send_error(client->fd, request_id,
			    "request-rejected", "presentation resolve request is invalid") != 0)
				engine_mux_client_free(client);
			return;
		}
		json_object_put(root);
		resolved = engine_pane_resolve_pid((pid_t)pid, &cause);
		if (resolved == NULL) {
			if (engine_mux_send_error(client->fd, request_id,
			    "request-rejected", cause == NULL ?
			    "presentation process has no owning pane" : cause) != 0)
				engine_mux_client_free(client);
			free(cause);
			return;
		}
		free(cause);
		response = json_object_new_object();
		if (response == NULL) {
			if (engine_mux_send_error(client->fd, request_id,
			    "server-error", "out of memory") != 0)
				engine_mux_client_free(client);
			return;
		}
		xsnprintf(pane_id, sizeof pane_id, "%%%u", resolved->id);
		json_object_object_add(response, "schema",
		    json_object_new_string("engine-mux/presentation-resolve-v1"));
		json_object_object_add(response, "pane_id",
		    json_object_new_string(pane_id));
		json_object_object_add(response, "generation",
		    json_object_new_int64(resolved->engine_generation));
		json_object_object_add(response, "presentation",
		    json_object_new_string(engine_pane_presentation_name(resolved)));
		json_object_object_add(response, "view_mode",
		    json_object_new_string(engine_pane_view_mode_name(resolved)));
		response_text = json_object_to_json_string_ext(response,
		    JSON_C_TO_STRING_PLAIN);
		if (engine_mux_send_frame(client->fd,
		    ENGINE_MUX_PRESENTATION_RESOLVE, request_id,
		    engine_mux_revision, response_text, strlen(response_text)) != 0) {
			json_object_put(response);
			engine_mux_client_free(client);
			return;
		}
		json_object_put(response);
		return;
	}
	if (type == ENGINE_MUX_PRESENTATION_MAP_REQUEST ||
	    type == ENGINE_MUX_PRESENTATION_UNMAP_REQUEST) {
		struct json_object *root;
		char *cause = NULL;
		const char *ack;
		uint16_t ack_type;
		int map = type == ENGINE_MUX_PRESENTATION_MAP_REQUEST;

		root = engine_mux_parse_json(packet + sizeof header, payload_size);
		free(packet);
		if (root == NULL) {
			if (engine_mux_send_error(client->fd, request_id,
			    "malformed-json", "presentation request is not valid JSON") != 0)
				engine_mux_client_free(client);
			return;
		}
		if (engine_mux_presentation_dispatch(root, map, &cause) != 0) {
			json_object_put(root);
			if (engine_mux_send_error(client->fd, request_id,
			    "request-rejected", cause == NULL ? "request failed" : cause) != 0)
				engine_mux_client_free(client);
			free(cause);
			return;
		}
		json_object_put(root);
		free(cause);
		engine_mux_frontend_sync();
		ack_type = map ? ENGINE_MUX_PRESENTATION_MAP_ACK :
		    ENGINE_MUX_PRESENTATION_UNMAP_ACK;
		ack = map ? presentation_map_ack : presentation_unmap_ack;
		if (engine_mux_send_frame(client->fd, ack_type, request_id,
		    engine_mux_revision, ack, strlen(ack)) != 0)
			engine_mux_client_free(client);
		return;
	}
	if (type == ENGINE_MUX_VIEW_REGISTER_REQUEST ||
	    type == ENGINE_MUX_KEY_REQUEST ||
	    type == ENGINE_MUX_MOUSE_REQUEST ||
	    type == ENGINE_MUX_VIEW_UNREGISTER_REQUEST ||
	    type == ENGINE_MUX_VIEW_FOCUS_REQUEST) {
		struct json_object *root;
		struct engine_mux_view *view;
		const char *schema;
		const char *ack;
		char *cause = NULL;
		u_int view_id;
		uint16_t ack_type;
		int result = -1;

		root = engine_mux_parse_json(packet + sizeof header, payload_size);
		free(packet);
		if (root == NULL) {
			if (engine_mux_send_error(client->fd, request_id,
			    "malformed-json", "request payload is not valid JSON") != 0)
				engine_mux_client_free(client);
			return;
		}
		if (type == ENGINE_MUX_VIEW_REGISTER_REQUEST) {
			result = engine_mux_view_register(client, root, &cause);
		} else if (type == ENGINE_MUX_KEY_REQUEST) {
			result = engine_mux_key_dispatch(client, root, &cause);
		} else if (type == ENGINE_MUX_MOUSE_REQUEST) {
			result = engine_mux_mouse_dispatch(client, root, &cause);
		} else if (type == ENGINE_MUX_VIEW_UNREGISTER_REQUEST) {
			schema = engine_mux_json_string_value(root, "schema", 64);
			if (schema != NULL && strcmp(schema,
			    "engine-mux/view-unregister-v1") == 0 &&
			    engine_mux_json_u32(root, "view_id", 1, UINT32_MAX,
			    &view_id) == 0 &&
			    (view = engine_mux_view_find(client, view_id)) != NULL) {
				engine_mux_view_free(client, view);
				result = 0;
			} else
				cause = xstrdup("graphical view unregister request is invalid");
		} else {
			schema = engine_mux_json_string_value(root, "schema", 64);
			if (schema != NULL && strcmp(schema,
			    "engine-mux/view-focus-v1") == 0 &&
			    engine_mux_json_u32(root, "view_id", 1, UINT32_MAX,
			    &view_id) == 0 &&
			    (view = engine_mux_view_find(client, view_id)) != NULL) {
				engine_mux_view_focus(view);
				result = 0;
			} else
				cause = xstrdup("graphical view focus request is invalid");
		}
		json_object_put(root);
		if (result != 0) {
			if (engine_mux_send_error(client->fd, request_id,
			    "request-rejected", cause == NULL ? "request failed" : cause) != 0)
				engine_mux_client_free(client);
			free(cause);
			return;
		}
		free(cause);
		if (type == ENGINE_MUX_VIEW_REGISTER_REQUEST) {
			ack_type = ENGINE_MUX_VIEW_REGISTER_ACK;
			ack = view_ack;
		} else if (type == ENGINE_MUX_KEY_REQUEST) {
			ack_type = ENGINE_MUX_KEY_ACK;
			ack = key_ack;
		} else if (type == ENGINE_MUX_MOUSE_REQUEST) {
			ack_type = ENGINE_MUX_MOUSE_ACK;
			ack = mouse_ack;
		} else if (type == ENGINE_MUX_VIEW_UNREGISTER_REQUEST) {
			ack_type = ENGINE_MUX_VIEW_UNREGISTER_ACK;
			ack = view_unregister_ack;
		} else {
			ack_type = ENGINE_MUX_VIEW_FOCUS_ACK;
			ack = view_focus_ack;
		}
		if (engine_mux_send_frame(client->fd, ack_type, request_id,
		    engine_mux_revision, ack, strlen(ack)) != 0)
			engine_mux_client_free(client);
		return;
	}
	if (type == ENGINE_MUX_UI_REQUEST) {
		struct json_object *root, *model;
		struct engine_mux_view *view, *other_view;
		const char *schema, *model_text;
		u_int view_id;
		size_t model_size;

		root = engine_mux_parse_json(packet + sizeof header, payload_size);
		free(packet);
		if (root == NULL) {
			if (engine_mux_send_error(client->fd, request_id,
			    "malformed-json", "UI request payload is not valid JSON") != 0)
				engine_mux_client_free(client);
			return;
		}
		schema = engine_mux_json_string_value(root, "schema", 64);
		if (schema == NULL || strcmp(schema, "engine-mux/ui-request-v1") != 0 ||
		    engine_mux_json_u32(root, "view_id", 1, UINT32_MAX,
		    &view_id) != 0 ||
		    (view = engine_mux_view_find(client, view_id)) == NULL) {
			json_object_put(root);
			if (engine_mux_send_error(client->fd, request_id,
			    "request-rejected", "UI request view is invalid") != 0)
				engine_mux_client_free(client);
			return;
		}
		json_object_put(root);
		model = engine_mux_build_ui_model(view);
		model_text = json_object_to_json_string_ext(model,
		    JSON_C_TO_STRING_PLAIN);
		model_size = strlen(model_text);
		if (model_size > ENGINE_MUX_MAX_PAYLOAD) {
			json_object_put(model);
			if (engine_mux_send_error(client->fd, request_id,
			    "payload-too-large", "UI model exceeds the frame limit") != 0)
				engine_mux_client_free(client);
			return;
		}
		if (engine_mux_send_frame(client->fd, ENGINE_MUX_UI_MODEL,
		    request_id, engine_mux_revision, model_text, model_size) != 0) {
			json_object_put(model);
			engine_mux_client_free(client);
			return;
		}
		TAILQ_FOREACH(other_view, &client->views, entry)
			other_view->ui_subscribed = 0;
		view->ui_subscribed = 1;
		view->ui_hash = engine_mux_ui_model_hash(model);
		json_object_put(model);
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
		} else {
			struct engine_mux_grid_state *state =
			    engine_mux_grid_find(pane->id);
			struct engine_mux_subscription *subscription =
			    engine_mux_subscription_find(client, pane->id);
			if (subscription != NULL) {
				subscription->hash = UINT64_C(1469598103934665603);
				engine_mux_hash_bytes(&subscription->hash, state->payload,
				    state->payload_size);
				subscription->invalidation_pending = 0;
			}
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
		} else {
			struct engine_mux_grid_state *state =
			    engine_mux_grid_find(pane->id);
			struct engine_mux_subscription *subscription =
			    engine_mux_subscription_find(client, pane->id);
			if (subscription != NULL) {
				subscription->hash = UINT64_C(1469598103934665603);
				engine_mux_hash_bytes(&subscription->hash, state->payload,
				    state->payload_size);
				subscription->invalidation_pending = 0;
			}
		}
		return;
	}
	if (type == ENGINE_MUX_GRID_SUBSCRIBE_REQUEST) {
		struct engine_mux_grid_state *state;
		struct engine_mux_subscription *subscription;

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
		subscription = engine_mux_subscription_find(client, pane->id);
		if (subscription == NULL) {
			subscription = xcalloc(1, sizeof *subscription);
			subscription->pane_id = pane->id;
			TAILQ_INSERT_TAIL(&client->subscriptions, subscription, entry);
		}
		subscription->generation = 1;
		subscription->hash = UINT64_C(1469598103934665603);
		engine_mux_hash_bytes(&subscription->hash, state->payload,
		    state->payload_size);
		subscription->invalidation_pending = 0;
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
	if (type == ENGINE_MUX_INPUT_REQUEST) {
		u_int input_length;

		if (payload_size < sizeof input_header) {
			free(packet);
			if (engine_mux_send_error(client->fd, request_id,
			    "malformed-input-request", "pane input header is truncated") != 0)
				engine_mux_client_free(client);
			return;
		}
		memcpy(&input_header, packet + sizeof header, sizeof input_header);
		input_length = ntohs(input_header.byte_length);
		if (ntohs(input_header.flags) != 0 || input_length == 0 ||
		    input_length > ENGINE_MUX_INPUT_MAX ||
		    payload_size != sizeof input_header + input_length) {
			free(packet);
			if (engine_mux_send_error(client->fd, request_id,
			    "malformed-input-request", "pane input payload is invalid") != 0)
				engine_mux_client_free(client);
			return;
		}
		if (ntohl(input_header.generation) != 1) {
			free(packet);
			if (engine_mux_send_error(client->fd, request_id,
			    "stale-generation", "pane generation is not current") != 0)
				engine_mux_client_free(client);
			return;
		}
		pane = window_pane_find_by_id(ntohl(input_header.pane_id));
		if (pane == NULL) {
			free(packet);
			if (engine_mux_send_error(client->fd, request_id,
			    "pane-not-found", "pane does not exist") != 0)
				engine_mux_client_free(client);
			return;
		}
		window_pane_paste(pane, KEYC_NONE,
		    (char *)packet + sizeof header + sizeof input_header,
		    input_length);
		free(packet);
		if (engine_mux_send_frame(client->fd, ENGINE_MUX_INPUT_ACK,
		    request_id, engine_mux_revision, input_ack, strlen(input_ack)) != 0)
			engine_mux_client_free(client);
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
	TAILQ_INIT(&client->views);
	TAILQ_INIT(&client->subscriptions);
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
