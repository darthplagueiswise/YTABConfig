#ifndef YTABC_RUNTIME_OVERRIDE_STATE_H
#define YTABC_RUNTIME_OVERRIDE_STATE_H

#include <stdbool.h>

typedef struct {
    bool hasOverride;
    bool overrideValue;
    bool hookInstalled;
} YTABCRuntimeOverrideState;

static inline YTABCRuntimeOverrideState YTABCRuntimeOverrideStateMake(void) {
    YTABCRuntimeOverrideState state = { false, false, false };
    return state;
}

static inline void YTABCRuntimeOverrideStateSetOverride(YTABCRuntimeOverrideState *state, bool value) {
    state->hasOverride = true;
    state->overrideValue = value;
}

static inline void YTABCRuntimeOverrideStateClearOverride(YTABCRuntimeOverrideState *state) {
    state->hasOverride = false;
}

static inline bool YTABCRuntimeOverrideStateMarkHookInstalled(YTABCRuntimeOverrideState *state) {
    if (state->hookInstalled) return false;
    state->hookInstalled = true;
    return true;
}

static inline bool YTABCRuntimeOverrideStateEffectiveValue(YTABCRuntimeOverrideState state, bool nativeValue) {
    return state.hasOverride ? state.overrideValue : nativeValue;
}

#endif
