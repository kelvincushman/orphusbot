/* Copyright (c) 2025-2026 Kelvin Lee. Licensed under MIT. Portions (c) 2024 Based Hardware Contributors, MIT (see LICENSE-UPSTREAM). */

#ifndef FEATURES_H
#define FEATURES_H

#include <stdint.h>

/**
 * @brief Defines the bitmask for available KelvinLee features.
 */
typedef enum {
    KELVINLEE_FEATURE_SPEAKER = (1 << 0),
    KELVINLEE_FEATURE_ACCELEROMETER = (1 << 1),
    KELVINLEE_FEATURE_BUTTON = (1 << 2),
    KELVINLEE_FEATURE_BATTERY = (1 << 3),
    KELVINLEE_FEATURE_USB = (1 << 4),
    KELVINLEE_FEATURE_HAPTIC = (1 << 5),
    KELVINLEE_FEATURE_OFFLINE_STORAGE = (1 << 6),
    KELVINLEE_FEATURE_LED_DIMMING = (1 << 7),
    KELVINLEE_FEATURE_MIC_GAIN = (1 << 8),
} kelvinlee_feature_t;

#endif // FEATURES_H
