#include <sys/types.h>

#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <systemd/sd-login.h>

#include "tmux.h"

static enum cmd_retval cmd_pane_presentation_exec(struct cmd *,
    struct cmdq_item *);
static enum cmd_retval cmd_launch_pane_app_exec(struct cmd *,
    struct cmdq_item *);
static enum cmd_retval cmd_signal_pane_app_exec(struct cmd *,
    struct cmdq_item *);
static enum cmd_retval cmd_respawn_pane_app_exec(struct cmd *,
    struct cmdq_item *);
static enum cmd_retval cmd_split_pane_app_exec(struct cmd *,
    struct cmdq_item *);

static u_int engine_split_serial;

const struct cmd_entry cmd_pane_presentation_entry = {
	.name = "pane-presentation",
	.alias = NULL,
	.args = { "t:", 1, 1, NULL },
	.usage = CMD_TARGET_PANE_USAGE " app|console|toggle|close",
	.target = { 't', CMD_FIND_PANE, 0 },
	.flags = CMD_AFTERHOOK,
	.exec = cmd_pane_presentation_exec
};

const struct cmd_entry cmd_launch_pane_app_entry = {
	.name = "launch-pane-app",
	.alias = NULL,
	.args = { "t:", 1, -1, NULL },
	.usage = CMD_TARGET_PANE_USAGE " -- command [argument ...]",
	.target = { 't', CMD_FIND_PANE, 0 },
	.flags = CMD_AFTERHOOK,
	.exec = cmd_launch_pane_app_exec
};

const struct cmd_entry cmd_signal_pane_app_entry = {
	.name = "signal-pane-app",
	.alias = NULL,
	.args = { "t:", 1, 1, NULL },
	.usage = CMD_TARGET_PANE_USAGE " INT|TERM|KILL",
	.target = { 't', CMD_FIND_PANE, 0 },
	.flags = CMD_AFTERHOOK,
	.exec = cmd_signal_pane_app_exec
};

const struct cmd_entry cmd_respawn_pane_app_entry = {
	.name = "respawn-pane-app",
	.alias = NULL,
	.args = { "t:", 0, 0, NULL },
	.usage = CMD_TARGET_PANE_USAGE,
	.target = { 't', CMD_FIND_PANE, 0 },
	.flags = CMD_AFTERHOOK,
	.exec = cmd_respawn_pane_app_exec
};

const struct cmd_entry cmd_split_pane_app_entry = {
	.name = "split-pane-app",
	.alias = NULL,
	.args = { "hvt:", 1, -1, NULL },
	.usage = "[-h|-v] " CMD_TARGET_PANE_USAGE " -- command [argument ...]",
	.target = { 't', CMD_FIND_PANE, 0 },
	.flags = CMD_AFTERHOOK,
	.exec = cmd_split_pane_app_exec
};

const char *
engine_pane_presentation_name(const struct window_pane *wp)
{
	switch (wp->engine_presentation) {
	case ENGINE_PANE_WAYLAND:
		return ("wayland");
	case ENGINE_PANE_GAME:
		return ("game");
	case ENGINE_PANE_STREAM:
		return ("stream");
	case ENGINE_PANE_TERMINAL:
	default:
		return ("terminal");
	}
}

const char *
engine_pane_view_mode_name(const struct window_pane *wp)
{
	return (wp->engine_view_mode == ENGINE_PANE_VIEW_CONSOLE ?
	    "console" : "presentation");
}

static void
engine_pane_changed(struct window_pane *wp)
{
	server_redraw_window_borders(wp->window);
	server_status_window(wp->window);
}

static void
engine_pane_console_message(struct window_pane *wp, const char *message)
{
	input_parse_buffer(wp, (u_char *)message, strlen(message));
}

void
engine_pane_surface_clear(struct window_pane *wp)
{
	struct engine_pane_surface *surface, *next;

	TAILQ_FOREACH_SAFE(surface, &wp->engine_surfaces, entry, next) {
		TAILQ_REMOVE(&wp->engine_surfaces, surface, entry);
		free(surface);
	}
}

static struct engine_pane_surface *
engine_pane_surface_find(struct window_pane *wp, u_int id)
{
	struct engine_pane_surface *surface;

	TAILQ_FOREACH(surface, &wp->engine_surfaces, entry) {
		if (surface->id == id)
			return (surface);
	}
	return (NULL);
}

struct window_pane *
engine_pane_resolve_pid(pid_t pid, char **cause)
{
	struct window_pane *wp, *match = NULL;
	char *unit = NULL;

	if (pid <= 0 || sd_pid_get_user_unit(pid, &unit) < 0 || unit == NULL) {
		free(unit);
		*cause = xstrdup("process is not in a registered user scope");
		return (NULL);
	}
	RB_FOREACH(wp, window_pane_tree, &all_window_panes) {
		if (wp->engine_presentation == ENGINE_PANE_TERMINAL ||
		    wp->engine_scope == NULL || strcmp(unit, wp->engine_scope) != 0)
			continue;
		if (match != NULL) {
			free(unit);
			*cause = xstrdup("process scope resolves to multiple panes");
			return (NULL);
		}
		match = wp;
	}
	free(unit);
	if (match == NULL)
		*cause = xstrdup("process is outside every pending pane launch scope");
	return (match);
}

int
engine_pane_surface_map(struct window_pane *wp, pid_t pid, u_int id,
    const char *role_name, char **cause)
{
	struct engine_pane_surface *surface;
	enum engine_pane_surface_role role;
	char *unit = NULL;

	if (wp->engine_presentation == ENGINE_PANE_TERMINAL ||
	    wp->engine_scope == NULL) {
		*cause = xstrdup("pane has no pending graphical launch");
		return (-1);
	}
	if (engine_pane_surface_find(wp, id) != NULL) {
		*cause = xstrdup("surface identifier is already mapped");
		return (-1);
	}
	if (strcmp(role_name, "toplevel") == 0)
		role = ENGINE_PANE_SURFACE_TOPLEVEL;
	else if (strcmp(role_name, "transient") == 0)
		role = ENGINE_PANE_SURFACE_TRANSIENT;
	else if (strcmp(role_name, "popup") == 0)
		role = ENGINE_PANE_SURFACE_POPUP;
	else {
		*cause = xstrdup("surface role is unsupported");
		return (-1);
	}
	if (pid <= 0 || sd_pid_get_user_unit(pid, &unit) < 0 ||
	    unit == NULL || strcmp(unit, wp->engine_scope) != 0) {
		free(unit);
		*cause = xstrdup("surface process is outside the pane launch scope");
		return (-1);
	}
	free(unit);
	surface = xcalloc(1, sizeof *surface);
	surface->id = id;
	surface->pid = pid;
	surface->role = role;
	TAILQ_INSERT_TAIL(&wp->engine_surfaces, surface, entry);
	if (role == ENGINE_PANE_SURFACE_TOPLEVEL) {
		wp->engine_surface_count++;
		wp->engine_mapped = 1;
		wp->engine_launch_deadline = 0;
		wp->engine_view_mode = ENGINE_PANE_VIEW_PRESENTATION;
	}
	engine_pane_changed(wp);
	return (0);
}

int
engine_pane_surface_unmap(struct window_pane *wp, pid_t pid, u_int id,
    char **cause)
{
	struct engine_pane_surface *surface;

	surface = engine_pane_surface_find(wp, id);
	if (surface == NULL || surface->pid != pid) {
		*cause = xstrdup("surface is not mapped to this pane process");
		return (-1);
	}
	if (surface->role == ENGINE_PANE_SURFACE_TOPLEVEL &&
	    wp->engine_surface_count > 0)
		wp->engine_surface_count--;
	TAILQ_REMOVE(&wp->engine_surfaces, surface, entry);
	free(surface);
	if (wp->engine_surface_count == 0) {
		wp->engine_mapped = 0;
		wp->engine_view_mode = ENGINE_PANE_VIEW_CONSOLE;
	}
	engine_pane_changed(wp);
	return (0);
}

static void
engine_pane_reset_runtime(struct window_pane *wp, int preserve_command)
{
	engine_pane_surface_clear(wp);
	wp->engine_presentation = ENGINE_PANE_TERMINAL;
	wp->engine_view_mode = ENGINE_PANE_VIEW_PRESENTATION;
	wp->engine_app_pgrp = 0;
	wp->engine_launch_deadline = 0;
	wp->engine_surface_count = 0;
	wp->engine_mapped = 0;
	free(wp->engine_scope);
	wp->engine_scope = NULL;
	if (!preserve_command) {
		free(wp->engine_command);
		wp->engine_command = NULL;
	}
	engine_pane_changed(wp);
}

static int
engine_pane_shell_is_foreground(struct window_pane *wp)
{
	pid_t foreground;

	if (wp->fd == -1 || wp->pid <= 0)
		return (0);
	foreground = tcgetpgrp(wp->fd);
	return (foreground == wp->pid);
}

static int
engine_pane_inject_launch(struct window_pane *wp, const char *command,
    char **cause)
{
	const char *user_runtime;
	char *line, *escaped_runtime = NULL;

	if (!engine_pane_shell_is_foreground(wp)) {
		*cause = xstrdup("pane shell is not the foreground process group");
		return (-1);
	}
	if (wp->engine_presentation != ENGINE_PANE_TERMINAL ||
	    wp->engine_app_pgrp != 0 || wp->engine_launch_deadline != 0) {
		*cause = xstrdup("pane already has an active graphical launch");
		return (-1);
	}
	wp->engine_launch_serial++;
	free(wp->engine_scope);
	xasprintf(&wp->engine_scope, "engine-pane-%lld-%u-%u.scope",
	    (long long)getpid(), wp->id, wp->engine_launch_serial);
	user_runtime = getenv("ENGINEOS_USER_RUNTIME_DIR");
	if (user_runtime != NULL && *user_runtime != '\0')
		escaped_runtime = args_escape(user_runtime);
	if (escaped_runtime == NULL)
		xasprintf(&line,
		    "systemd-run --user --scope --collect --unit=%s -- %s\n",
		    wp->engine_scope, command);
	else
		xasprintf(&line,
		    "env XDG_RUNTIME_DIR=%s systemd-run --user --scope --collect --unit=%s -- %s\n",
		    escaped_runtime, wp->engine_scope, command);
	free(escaped_runtime);
	bufferevent_write(wp->event, line, strlen(line));
	free(line);
	wp->engine_presentation = ENGINE_PANE_WAYLAND;
	wp->engine_view_mode = ENGINE_PANE_VIEW_CONSOLE;
	wp->engine_app_pgrp = 0;
	wp->engine_launch_deadline = time(NULL) + 15;
	wp->engine_surface_count = 0;
	wp->engine_mapped = 0;
	engine_pane_changed(wp);
	return (0);
}

static enum cmd_retval
cmd_launch_pane_app_exec(struct cmd *self, struct cmdq_item *item)
{
	struct args *args = cmd_get_args(self);
	struct window_pane *wp = cmdq_get_target(item)->wp;
	char **argv, *command, *cause = NULL;
	int argc;

	args_to_vector(args, &argc, &argv);
	command = cmd_stringify_argv(argc, argv);
	cmd_free_argv(argc, argv);
	if (command == NULL || *command == '\0') {
		free(command);
		cmdq_error(item, "command is empty");
		return (CMD_RETURN_ERROR);
	}
	if (engine_pane_inject_launch(wp, command, &cause) != 0) {
		cmdq_error(item, "%s", cause);
		free(cause);
		free(command);
		return (CMD_RETURN_ERROR);
	}
	free(wp->engine_command);
	wp->engine_command = command;
	return (CMD_RETURN_NORMAL);
}

static enum cmd_retval
cmd_pane_presentation_exec(struct cmd *self, struct cmdq_item *item)
{
	struct args *args = cmd_get_args(self);
	struct window_pane *wp = cmdq_get_target(item)->wp;
	const char *mode = args_string(args, 0);

	if (strcmp(mode, "console") == 0) {
		wp->engine_view_mode = ENGINE_PANE_VIEW_CONSOLE;
	} else if (strcmp(mode, "app") == 0) {
		if (wp->engine_presentation == ENGINE_PANE_TERMINAL ||
		    !wp->engine_mapped) {
			cmdq_error(item, "pane has no mapped graphical presentation");
			return (CMD_RETURN_ERROR);
		}
		wp->engine_view_mode = ENGINE_PANE_VIEW_PRESENTATION;
	} else if (strcmp(mode, "toggle") == 0) {
		if (wp->engine_presentation == ENGINE_PANE_TERMINAL ||
		    !wp->engine_mapped) {
			cmdq_error(item, "pane has no mapped graphical presentation");
			return (CMD_RETURN_ERROR);
		}
		wp->engine_view_mode = wp->engine_view_mode ==
		    ENGINE_PANE_VIEW_CONSOLE ? ENGINE_PANE_VIEW_PRESENTATION :
		    ENGINE_PANE_VIEW_CONSOLE;
	} else if (strcmp(mode, "close") == 0) {
		if (wp->engine_presentation == ENGINE_PANE_TERMINAL) {
			cmdq_error(item, "pane has no graphical presentation");
			return (CMD_RETURN_ERROR);
		}
		if (wp->engine_app_pgrp > 0)
			kill(-wp->engine_app_pgrp, SIGTERM);
		engine_pane_reset_runtime(wp, 0);
		return (CMD_RETURN_NORMAL);
	} else {
		cmdq_error(item, "unknown presentation mode: %s", mode);
		return (CMD_RETURN_ERROR);
	}
	engine_pane_changed(wp);
	return (CMD_RETURN_NORMAL);
}

static enum cmd_retval
cmd_signal_pane_app_exec(struct cmd *self, struct cmdq_item *item)
{
	struct args *args = cmd_get_args(self);
	struct window_pane *wp = cmdq_get_target(item)->wp;
	const char *name = args_string(args, 0);
	int signal_number;

	if (strcmp(name, "INT") == 0)
		signal_number = SIGINT;
	else if (strcmp(name, "TERM") == 0)
		signal_number = SIGTERM;
	else if (strcmp(name, "KILL") == 0)
		signal_number = SIGKILL;
	else {
		cmdq_error(item, "unsupported signal: %s", name);
		return (CMD_RETURN_ERROR);
	}
	if (wp->engine_app_pgrp <= 0 ||
	    kill(-wp->engine_app_pgrp, signal_number) != 0) {
		cmdq_error(item, "pane graphical process group is unavailable");
		return (CMD_RETURN_ERROR);
	}
	return (CMD_RETURN_NORMAL);
}

static enum cmd_retval
cmd_respawn_pane_app_exec(__unused struct cmd *self, struct cmdq_item *item)
{
	struct window_pane *wp = cmdq_get_target(item)->wp;
	char *cause = NULL;

	if (wp->engine_command == NULL) {
		cmdq_error(item, "pane has no saved graphical command");
		return (CMD_RETURN_ERROR);
	}
	if (engine_pane_inject_launch(wp, wp->engine_command, &cause) != 0) {
		cmdq_error(item, "%s", cause);
		free(cause);
		return (CMD_RETURN_ERROR);
	}
	return (CMD_RETURN_NORMAL);
}

static enum cmd_retval
cmd_split_pane_app_exec(struct cmd *self, struct cmdq_item *item)
{
	struct args *args = cmd_get_args(self);
	struct cmd_find_state *current = cmdq_get_current(item);
	struct cmd_find_state *target = cmdq_get_target(item);
	struct session *session = target->s;
	struct winlink *wl = target->wl;
	struct window_pane *wp = target->wp, *new_wp;
	struct layout_cell *lc;
	struct spawn_context sc = { 0 };
	struct cmd_find_state fs;
	enum layout_type type;
	char **app_argv, *command, *scope, *cause = NULL;
	int app_argc, i;

	if (args_has(args, 'h') && args_has(args, 'v')) {
		cmdq_error(item, "horizontal and vertical split modes conflict");
		return (CMD_RETURN_ERROR);
	}
	args_to_vector(args, &app_argc, &app_argv);
	command = cmd_stringify_argv(app_argc, app_argv);
	if (command == NULL || *command == '\0') {
		cmd_free_argv(app_argc, app_argv);
		free(command);
		cmdq_error(item, "command is empty");
		return (CMD_RETURN_ERROR);
	}
	type = args_has(args, 'h') ? LAYOUT_LEFTRIGHT : LAYOUT_TOPBOTTOM;
	window_push_zoom(wp->window, 1, 0);
	lc = layout_split_pane(wp, type, -1, 0);
	if (lc == NULL) {
		window_pop_zoom(wp->window);
		cmd_free_argv(app_argc, app_argv);
		free(command);
		cmdq_error(item, "no space for new pane");
		return (CMD_RETURN_ERROR);
	}
	xasprintf(&scope, "engine-pane-split-%lld-%u.scope",
	    (long long)getpid(), ++engine_split_serial);
	sc.item = item;
	sc.s = session;
	sc.wl = wl;
	sc.wp0 = wp;
	sc.lc = lc;
	sc.argc = app_argc + 4;
	sc.argv = xcalloc(sc.argc, sizeof *sc.argv);
	sc.argv[0] = xstrdup("engine-pane-host");
	sc.argv[1] = xstrdup("--scope");
	sc.argv[2] = xstrdup(scope);
	sc.argv[3] = xstrdup("--");
	for (i = 0; i < app_argc; i++)
		sc.argv[i + 4] = xstrdup(app_argv[i]);
	sc.environ = environ_create();
	sc.idx = -1;
	if ((new_wp = spawn_pane(&sc, &cause)) == NULL) {
		cmdq_error(item, "create graphical pane failed: %s", cause);
		free(cause);
		cmd_free_argv(sc.argc, sc.argv);
		environ_free(sc.environ);
		cmd_free_argv(app_argc, app_argv);
		free(command);
		free(scope);
		window_pop_zoom(wp->window);
		return (CMD_RETURN_ERROR);
	}
	new_wp->engine_presentation = ENGINE_PANE_WAYLAND;
	new_wp->engine_view_mode = ENGINE_PANE_VIEW_CONSOLE;
	new_wp->engine_scope = scope;
	new_wp->engine_command = command;
	new_wp->engine_launch_deadline = time(NULL) + 15;
	cmd_find_from_winlink_pane(current, wl, new_wp, 0);
	window_pop_zoom(wp->window);
	server_redraw_window(wp->window);
	server_status_session(session);
	cmd_find_from_winlink_pane(&fs, wl, new_wp, 0);
	cmdq_insert_hook(session, item, &fs, "after-split-window");
	cmd_free_argv(sc.argc, sc.argv);
	environ_free(sc.environ);
	cmd_free_argv(app_argc, app_argv);
	return (CMD_RETURN_NORMAL);
}

void
engine_pane_sync_all(void)
{
	struct window_pane *wp;
	pid_t foreground;
	time_t now = time(NULL);

	RB_FOREACH(wp, window_pane_tree, &all_window_panes) {
		if (wp->engine_presentation == ENGINE_PANE_TERMINAL)
			continue;
		foreground = wp->fd == -1 ? -1 : tcgetpgrp(wp->fd);
		if (wp->engine_app_pgrp == 0 && foreground > 0 &&
		    foreground != wp->pid) {
			wp->engine_app_pgrp = foreground;
			engine_pane_changed(wp);
		}
		if (!wp->engine_mapped && wp->engine_launch_deadline != 0 &&
		    now >= wp->engine_launch_deadline) {
			if (wp->engine_app_pgrp > 0)
				kill(-wp->engine_app_pgrp, SIGTERM);
			engine_pane_console_message(wp,
			    "\r\nengineos: graphical launch mapped no surface within 15 seconds\r\n");
			engine_pane_reset_runtime(wp, 1);
			continue;
		}
		/* systemd-run may briefly return the terminal to the shell before the
		 * first surface maps. A nonzero deadline identifies that pending state;
		 * only retire a previously mapped launch after its process group is
		 * actually gone. A split-pane host is the exception: it intentionally
		 * becomes the pane's login shell when its initial app exits. */
		if (wp->engine_app_pgrp > 0 && foreground == wp->pid &&
		    (wp->engine_launch_deadline == 0 ||
		    (wp->engine_scope != NULL && strncmp(wp->engine_scope,
		    "engine-pane-split-", 18) == 0)) &&
		    kill(-wp->engine_app_pgrp, 0) != 0 && errno == ESRCH) {
			engine_pane_reset_runtime(wp, 1);
			continue;
		}
	}
}
