#ifndef ENGINE_MUX_FRONTEND_H
#define ENGINE_MUX_FRONTEND_H

int engine_mux_frontend_init(void);
void engine_mux_frontend_sync(void);
void engine_mux_frontend_free(void);
int engine_mux_frontend_owns_window(struct window *);

#endif
