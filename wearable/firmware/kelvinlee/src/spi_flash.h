/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. Portions (c) 2024 Based Hardware Contributors, MIT (see LICENSE-UPSTREAM). */

#ifndef SPI_FLASH_H
#define SPI_FLASH_H

#include <zephyr/kernel.h>

/**
 * @brief Initialize the SPI flash module.
 *
 * @return 0 on success, negative error code otherwise.
 */
int flash_init(void);

/**
 * @brief Put the SPI flash into a low-power (suspend/deep power down) state.
 *
 * @return 0 on success, negative error code on failure to suspend.
 */
int flash_off(void);

#endif // SPI_FLASH_H
