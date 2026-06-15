#define _POSIX_C_SOURCE 200809L

#include <SDL2/SDL.h>
#include <SDL2/SDL_opengles2.h>
#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifndef ENGINEOS_PI
#define ENGINEOS_PI 3.14159265358979323846f
#endif

struct cube_options {
	bool smoke;
	int smoke_ms;
};

static void usage(FILE *out, const char *argv0) {
	fprintf(out,
		"Usage: %s [--smoke] [--smoke-ms N]\n"
		"\n"
		"Render the EngineOS rotating cube Wayland/OpenGL ES client.\n",
		argv0);
}

static double monotonic_ms(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

static bool parse_options(int argc, char **argv, struct cube_options *options) {
	options->smoke = false;
	options->smoke_ms = 1500;

	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--smoke") == 0) {
			options->smoke = true;
		} else if (strcmp(argv[i], "--smoke-ms") == 0) {
			if (i + 1 >= argc) {
				fprintf(stderr, "engineos-cube: --smoke-ms requires a value\n");
				return false;
			}
			options->smoke_ms = atoi(argv[++i]);
			if (options->smoke_ms <= 0) {
				fprintf(stderr, "engineos-cube: --smoke-ms must be positive\n");
				return false;
			}
		} else if (strcmp(argv[i], "--help") == 0 ||
				strcmp(argv[i], "-h") == 0) {
			usage(stdout, argv[0]);
			exit(0);
		} else {
			fprintf(stderr, "engineos-cube: unknown option: %s\n", argv[i]);
			return false;
		}
	}

	return true;
}

static GLuint compile_shader(GLenum type, const char *source) {
	GLuint shader = glCreateShader(type);
	glShaderSource(shader, 1, &source, NULL);
	glCompileShader(shader);

	GLint ok = GL_FALSE;
	glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
	if (ok != GL_TRUE) {
		char log[1024];
		glGetShaderInfoLog(shader, sizeof(log), NULL, log);
		fprintf(stderr, "engineos-cube: shader compile failed: %s\n", log);
		glDeleteShader(shader);
		return 0;
	}

	return shader;
}

static GLuint create_program(void) {
	static const char *vertex_shader =
		"attribute vec3 a_position;\n"
		"attribute vec3 a_color;\n"
		"uniform mat4 u_mvp;\n"
		"varying vec3 v_color;\n"
		"void main(void) {\n"
		"  v_color = a_color;\n"
		"  gl_Position = u_mvp * vec4(a_position, 1.0);\n"
		"}\n";
	static const char *fragment_shader =
		"precision mediump float;\n"
		"varying vec3 v_color;\n"
		"void main(void) {\n"
		"  gl_FragColor = vec4(v_color, 1.0);\n"
		"}\n";

	GLuint vs = compile_shader(GL_VERTEX_SHADER, vertex_shader);
	GLuint fs = compile_shader(GL_FRAGMENT_SHADER, fragment_shader);
	if (vs == 0 || fs == 0) {
		glDeleteShader(vs);
		glDeleteShader(fs);
		return 0;
	}

	GLuint program = glCreateProgram();
	glAttachShader(program, vs);
	glAttachShader(program, fs);
	glBindAttribLocation(program, 0, "a_position");
	glBindAttribLocation(program, 1, "a_color");
	glLinkProgram(program);

	glDeleteShader(vs);
	glDeleteShader(fs);

	GLint ok = GL_FALSE;
	glGetProgramiv(program, GL_LINK_STATUS, &ok);
	if (ok != GL_TRUE) {
		char log[1024];
		glGetProgramInfoLog(program, sizeof(log), NULL, log);
		fprintf(stderr, "engineos-cube: program link failed: %s\n", log);
		glDeleteProgram(program);
		return 0;
	}

	return program;
}

static void mat4_identity(float out[16]) {
	for (int i = 0; i < 16; i++) {
		out[i] = 0.0f;
	}
	out[0] = 1.0f;
	out[5] = 1.0f;
	out[10] = 1.0f;
	out[15] = 1.0f;
}

static void mat4_multiply(float out[16], const float a[16], const float b[16]) {
	float tmp[16];
	for (int col = 0; col < 4; col++) {
		for (int row = 0; row < 4; row++) {
			tmp[col * 4 + row] =
				a[0 * 4 + row] * b[col * 4 + 0] +
				a[1 * 4 + row] * b[col * 4 + 1] +
				a[2 * 4 + row] * b[col * 4 + 2] +
				a[3 * 4 + row] * b[col * 4 + 3];
		}
	}
	memcpy(out, tmp, sizeof(tmp));
}

static void mat4_perspective(float out[16], float fovy_radians, float aspect,
		float near_z, float far_z) {
	float f = 1.0f / tanf(fovy_radians * 0.5f);
	for (int i = 0; i < 16; i++) {
		out[i] = 0.0f;
	}
	out[0] = f / aspect;
	out[5] = f;
	out[10] = (far_z + near_z) / (near_z - far_z);
	out[11] = -1.0f;
	out[14] = (2.0f * far_z * near_z) / (near_z - far_z);
}

static void mat4_translate(float out[16], float x, float y, float z) {
	mat4_identity(out);
	out[12] = x;
	out[13] = y;
	out[14] = z;
}

static void mat4_rotate_x(float out[16], float radians) {
	float c = cosf(radians);
	float s = sinf(radians);
	mat4_identity(out);
	out[5] = c;
	out[6] = s;
	out[9] = -s;
	out[10] = c;
}

static void mat4_rotate_y(float out[16], float radians) {
	float c = cosf(radians);
	float s = sinf(radians);
	mat4_identity(out);
	out[0] = c;
	out[2] = -s;
	out[8] = s;
	out[10] = c;
}

static void build_mvp(float out[16], int width, int height, float seconds) {
	float projection[16];
	float translate[16];
	float rotate_x[16];
	float rotate_y[16];
	float model_a[16];
	float model[16];
	float view_model[16];
	float aspect = height > 0 ? (float)width / (float)height : 1.0f;

	mat4_perspective(projection, 60.0f * ENGINEOS_PI / 180.0f, aspect, 0.1f, 100.0f);
	mat4_translate(translate, 0.0f, 0.0f, -5.0f);
	mat4_rotate_x(rotate_x, seconds * 0.8f);
	mat4_rotate_y(rotate_y, seconds * 1.1f);
	mat4_multiply(model_a, rotate_y, rotate_x);
	mat4_multiply(model, translate, model_a);
	mat4_multiply(view_model, projection, model);
	memcpy(out, view_model, sizeof(float) * 16);
}

int main(int argc, char **argv) {
	struct cube_options options;
	if (!parse_options(argc, argv, &options)) {
		usage(stderr, argv[0]);
		return 2;
	}

#ifdef SDL_HINT_APP_NAME
	SDL_SetHint(SDL_HINT_APP_NAME, "engineos-cube");
#endif
#ifdef SDL_HINT_VIDEO_WAYLAND_WMCLASS
	SDL_SetHint(SDL_HINT_VIDEO_WAYLAND_WMCLASS, "engineos-cube");
#endif

	if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_TIMER) != 0) {
		fprintf(stderr, "engineos-cube: SDL_Init failed: %s\n", SDL_GetError());
		return 1;
	}

	SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_ES);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 2);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 0);
	SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
	SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 24);

	SDL_Window *window = SDL_CreateWindow(
		"engineos-cube",
		SDL_WINDOWPOS_CENTERED,
		SDL_WINDOWPOS_CENTERED,
		960,
		540,
		SDL_WINDOW_OPENGL | SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE);
	if (window == NULL) {
		fprintf(stderr, "engineos-cube: SDL_CreateWindow failed: %s\n", SDL_GetError());
		SDL_Quit();
		return 1;
	}

	SDL_GLContext context = SDL_GL_CreateContext(window);
	if (context == NULL) {
		fprintf(stderr, "engineos-cube: SDL_GL_CreateContext failed: %s\n", SDL_GetError());
		SDL_DestroyWindow(window);
		SDL_Quit();
		return 1;
	}
	SDL_GL_SetSwapInterval(1);

	GLuint program = create_program();
	if (program == 0) {
		SDL_GL_DeleteContext(context);
		SDL_DestroyWindow(window);
		SDL_Quit();
		return 1;
	}

	static const GLfloat vertices[] = {
		-1.0f, -1.0f, -1.0f, 0.95f, 0.20f, 0.24f,
		 1.0f, -1.0f, -1.0f, 0.95f, 0.68f, 0.24f,
		 1.0f,  1.0f, -1.0f, 0.98f, 0.91f, 0.30f,
		-1.0f,  1.0f, -1.0f, 0.20f, 0.76f, 0.44f,
		-1.0f, -1.0f,  1.0f, 0.18f, 0.60f, 0.86f,
		 1.0f, -1.0f,  1.0f, 0.47f, 0.33f, 0.86f,
		 1.0f,  1.0f,  1.0f, 0.84f, 0.30f, 0.70f,
		-1.0f,  1.0f,  1.0f, 0.93f, 0.93f, 0.93f,
	};
	static const GLushort indices[] = {
		0, 1, 2, 2, 3, 0,
		4, 6, 5, 6, 4, 7,
		0, 4, 5, 5, 1, 0,
		3, 2, 6, 6, 7, 3,
		1, 5, 6, 6, 2, 1,
		0, 3, 7, 7, 4, 0,
	};

	GLuint vbo = 0;
	GLuint ibo = 0;
	glGenBuffers(1, &vbo);
	glGenBuffers(1, &ibo);
	glBindBuffer(GL_ARRAY_BUFFER, vbo);
	glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);
	glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ibo);
	glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(indices), indices, GL_STATIC_DRAW);

	GLint mvp_location = glGetUniformLocation(program, "u_mvp");
	glEnable(GL_DEPTH_TEST);
	glEnable(GL_CULL_FACE);
	glCullFace(GL_BACK);
	glClearColor(0.02f, 0.025f, 0.03f, 1.0f);

	printf("EngineOS cube app\n");
	printf("video_driver=%s\n", SDL_GetCurrentVideoDriver());
	printf("gl_vendor=%s\n", (const char *)glGetString(GL_VENDOR));
	printf("gl_renderer=%s\n", (const char *)glGetString(GL_RENDERER));
	printf("gl_version=%s\n", (const char *)glGetString(GL_VERSION));
	fflush(stdout);

	bool running = true;
	unsigned int frames = 0;
	bool logged_first_frame = false;
	double start = monotonic_ms();

	while (running) {
		SDL_Event event;
		while (SDL_PollEvent(&event)) {
			if (event.type == SDL_QUIT) {
				running = false;
			}
			if (event.type == SDL_KEYDOWN &&
					event.key.keysym.sym == SDLK_ESCAPE) {
				running = false;
			}
		}

		int width = 0;
		int height = 0;
		SDL_GL_GetDrawableSize(window, &width, &height);
		if (width <= 0) {
			width = 1;
		}
		if (height <= 0) {
			height = 1;
		}

		float seconds = (float)((monotonic_ms() - start) / 1000.0);
		float mvp[16];
		build_mvp(mvp, width, height, seconds);

		glViewport(0, 0, width, height);
		glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
		glUseProgram(program);
		glUniformMatrix4fv(mvp_location, 1, GL_FALSE, mvp);
		glBindBuffer(GL_ARRAY_BUFFER, vbo);
		glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ibo);
		glEnableVertexAttribArray(0);
		glEnableVertexAttribArray(1);
		glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE,
			6 * (GLsizei)sizeof(GLfloat), (const GLvoid *)0);
		glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE,
			6 * (GLsizei)sizeof(GLfloat),
			(const GLvoid *)(3 * sizeof(GLfloat)));
		glDrawElements(GL_TRIANGLES, 36, GL_UNSIGNED_SHORT, 0);
		SDL_GL_SwapWindow(window);
		frames++;
		if (!logged_first_frame) {
			printf("frames=%u\n", frames);
			fflush(stdout);
			logged_first_frame = true;
		}

		if (options.smoke &&
				(monotonic_ms() - start) >= (double)options.smoke_ms) {
			running = false;
		}
	}

	printf("frames=%u\n", frames);
	printf("result=%s\n", options.smoke ? "smoke-ok" : "ok");
	fflush(stdout);

	glDeleteBuffers(1, &ibo);
	glDeleteBuffers(1, &vbo);
	glDeleteProgram(program);
	SDL_GL_DeleteContext(context);
	SDL_DestroyWindow(window);
	SDL_Quit();
	return 0;
}
