#ifndef LITEBAR_CORE_H
#define LITEBAR_CORE_H
#include <stdint.h>
#include <stddef.h>
typedef struct { double x, y, width, height; } LBRect;
typedef struct { uint32_t flags, rehide_strategy; uint64_t rehide_ms, hover_ms; } LBConfig;
typedef struct {
    uint32_t revealed, panel, pointer, buttons, tracking, hover_blocked, suspended, reserved;
    uint64_t hover_deadline, rehide_deadline, last_time;
} LBState;
typedef struct {
    uint32_t event_type, mouse_button;
    uint64_t flags;
    int32_t click_count;
    uint32_t valid;
} LBEventSpec;
uint32_t lb_abi_version(void);
LBConfig lb_default_config(void);
LBState lb_initial_state(void);
LBState lb_step(LBState, LBConfig, uint32_t, uint64_t);
LBState lb_reconfigure(LBState, LBConfig, uint64_t);
uint64_t lb_next_deadline(LBState);
double lb_hidden_length(LBState, LBConfig);
double lb_always_length(LBState, LBConfig);
uint32_t lb_section_mask(LBRect, LBRect, LBRect, uint32_t);
int32_t lb_search_score(const uint8_t *, size_t, const uint8_t *, size_t);
uint32_t lb_identity_flags(const uint8_t *, size_t, const uint8_t *, size_t);
LBEventSpec lb_event_spec(uint32_t, uint32_t);
uint32_t lb_classic_transition(uint32_t, uint32_t, uint32_t);
#endif
