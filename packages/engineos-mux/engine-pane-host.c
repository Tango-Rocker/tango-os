#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L

#include <sys/types.h>
#include <sys/wait.h>

#include <errno.h>
#include <pwd.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void
usage(const char *program)
{
	fprintf(stderr, "usage: %s --scope UNIT -- COMMAND [ARG ...]\n", program);
}

static int
run_app_scope(const char *scope, int argc, char **argv)
{
	const char *user_runtime;
	char **scope_argv, *unit;
	pid_t child, result;
	int status, i;
	struct sigaction ignore = { 0 }, previous;

	user_runtime = getenv("ENGINEOS_USER_RUNTIME_DIR");
	if (user_runtime != NULL && *user_runtime != '\0' &&
	    setenv("XDG_RUNTIME_DIR", user_runtime, 1) != 0)
		return (-1);
	if (asprintf(&unit, "--unit=%s", scope) < 0)
		return (-1);
	scope_argv = calloc((size_t)argc + 7, sizeof *scope_argv);
	if (scope_argv == NULL) {
		free(unit);
		return (-1);
	}
	scope_argv[0] = "systemd-run";
	scope_argv[1] = "--user";
	scope_argv[2] = "--scope";
	scope_argv[3] = "--collect";
	scope_argv[4] = unit;
	scope_argv[5] = "--";
	for (i = 0; i < argc; i++)
		scope_argv[i + 6] = argv[i];
	ignore.sa_handler = SIG_IGN;
	sigemptyset(&ignore.sa_mask);
	if (sigaction(SIGTTOU, &ignore, &previous) != 0) {
		free(scope_argv);
		free(unit);
		return (-1);
	}
	child = fork();
	if (child == -1) {
		sigaction(SIGTTOU, &previous, NULL);
		free(scope_argv);
		free(unit);
		return (-1);
	}
	if (child == 0) {
		setpgid(0, 0);
		if (isatty(STDIN_FILENO))
			tcsetpgrp(STDIN_FILENO, getpid());
		execvp(scope_argv[0], scope_argv);
		fprintf(stderr, "engine-pane-host: systemd-run: %s\n",
		    strerror(errno));
		_exit(127);
	}
	setpgid(child, child);
	if (isatty(STDIN_FILENO))
		tcsetpgrp(STDIN_FILENO, child);
	do
		result = waitpid(child, &status, 0);
	while (result == -1 && errno == EINTR);
	if (isatty(STDIN_FILENO))
		tcsetpgrp(STDIN_FILENO, getpgrp());
	sigaction(SIGTTOU, &previous, NULL);
	free(scope_argv);
	free(unit);
	if (result == -1)
		return (-1);
	if (WIFEXITED(status))
		return (WEXITSTATUS(status));
	if (WIFSIGNALED(status))
		return (128 + WTERMSIG(status));
	return (-1);
}

static void
start_login_shell(void)
{
	struct passwd *password;
	const char *shell, *base;
	char *login_name;

	password = getpwuid(getuid());
	shell = password != NULL && password->pw_shell != NULL &&
	    *password->pw_shell != '\0' ? password->pw_shell : "/bin/sh";
	base = strrchr(shell, '/');
	base = base == NULL ? shell : base + 1;
	if (asprintf(&login_name, "-%s", base) < 0)
		_exit(127);
	execl(shell, login_name, (char *)NULL);
	fprintf(stderr, "engine-pane-host: login shell %s: %s\n", shell,
	    strerror(errno));
	free(login_name);
	_exit(127);
}

int
main(int argc, char **argv)
{
	const char *scope;
	int app_index, status;

	if (argc < 5 || strcmp(argv[1], "--scope") != 0 ||
	    strcmp(argv[3], "--") != 0) {
		usage(argv[0]);
		return (2);
	}
	scope = argv[2];
	app_index = 4;
	status = run_app_scope(scope, argc - app_index, argv + app_index);
	if (status < 0)
		fprintf(stderr, "engine-pane-host: application scope failed: %s\n",
		    strerror(errno));
	start_login_shell();
}
