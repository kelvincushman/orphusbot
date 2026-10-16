/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. Portions (c) 2024 Based Hardware Contributors, MIT (see LICENSE-UPSTREAM). */

#ifndef BUTTON_H
#define BUTTON_H

typedef enum { IDLE, GRACE } FSM_STATE_T;

int button_init();
void activate_button_work();
void register_button_service();
void turnoff_all();
FSM_STATE_T get_current_button_state();

void force_button_state(FSM_STATE_T state);

/* Call from the 0xCAB1AB97 write handler on every write the phone makes.
 * Disarms the gesture-confirmation watchdog and marks the app alive. */
void button_note_app_ack();

#endif
