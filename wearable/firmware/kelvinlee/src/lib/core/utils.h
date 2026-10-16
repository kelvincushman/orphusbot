/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. Portions (c) 2024 Based Hardware Contributors, MIT (see LICENSE-UPSTREAM). */

#ifndef UTILS_H
#define UTILS_H

#include <zephyr/bluetooth/gatt.h>
#include <zephyr/logging/log.h>

#define ASSERT_OK(result)                                                                                              \
    if ((result) < 0) {                                                                                                \
        LOG_ERR("Error at %s:%d:%d", __FILE__, __LINE__, result);                                                      \
        return (result);                                                                                               \
    }

#define ASSERT_TRUE(result)                                                                                            \
    if (!result) {                                                                                                     \
        LOG_ERR("Error at %s:%d:%d", __FILE__, __LINE__, result);                                                      \
        return -1;                                                                                                     \
    }

#endif