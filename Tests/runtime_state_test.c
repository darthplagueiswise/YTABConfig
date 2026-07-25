#include <assert.h>
#include <stdbool.h>

#include "../RuntimeOverrideState.h"

static void test_untouched_state_uses_current_native_value(void) {
    YTABCRuntimeOverrideState state = YTABCRuntimeOverrideStateMake();

    assert(YTABCRuntimeOverrideStateEffectiveValue(state, false) == false);
    assert(YTABCRuntimeOverrideStateEffectiveValue(state, true) == true);
    assert(state.hookInstalled == false);
}

static void test_override_wins_and_hook_transition_is_idempotent(void) {
    YTABCRuntimeOverrideState state = YTABCRuntimeOverrideStateMake();

    YTABCRuntimeOverrideStateSetOverride(&state, true);
    assert(state.hasOverride == true);
    assert(YTABCRuntimeOverrideStateEffectiveValue(state, false) == true);
    assert(YTABCRuntimeOverrideStateMarkHookInstalled(&state) == true);
    assert(YTABCRuntimeOverrideStateMarkHookInstalled(&state) == false);
}

static void test_clear_restores_live_native_behavior_without_unhooking(void) {
    YTABCRuntimeOverrideState state = YTABCRuntimeOverrideStateMake();

    YTABCRuntimeOverrideStateSetOverride(&state, false);
    assert(YTABCRuntimeOverrideStateMarkHookInstalled(&state) == true);
    YTABCRuntimeOverrideStateClearOverride(&state);

    assert(state.hasOverride == false);
    assert(state.hookInstalled == true);
    assert(YTABCRuntimeOverrideStateEffectiveValue(state, false) == false);
    assert(YTABCRuntimeOverrideStateEffectiveValue(state, true) == true);
}

int main(void) {
    test_untouched_state_uses_current_native_value();
    test_override_wins_and_hook_transition_is_idempotent();
    test_clear_restores_live_native_behavior_without_unhooking();
    return 0;
}
