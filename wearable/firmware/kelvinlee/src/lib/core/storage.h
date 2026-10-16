/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. Portions (c) 2024 Based Hardware Contributors, MIT (see LICENSE-UPSTREAM). */

#ifndef STORAGE_H
#define STORAGE_H

#ifdef CONFIG_KELVINLEE_ENABLE_OFFLINE_STORAGE

#include <stdbool.h>

/**
 * @brief Initializes the Storage Transport thread
 *
 * Initializes the Storage Transport thread
 *
 * @return 0 if successful, negative errno code if error
 */
int storage_init();

#endif // CONFIG_KELVINLEE_ENABLE_OFFLINE_STORAGE

#endif // STORAGE_H
