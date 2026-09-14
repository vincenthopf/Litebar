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

uint32_t lb_window_server_available(void);
uint64_t lb_active_space(void);
uint32_t lb_fullscreen(void);
uint32_t lb_window_frame(uint32_t, LBRect *);
const void *lb_copy_window_descriptions(void);
int32_t lb_cursor_property(void);
uint32_t lb_set_cursor_property(uint32_t);
int32_t lb_process_responsivity(int32_t);

typedef struct {
    uint32_t window_id;
    int32_t process_id;
    uint32_t display_id, flags;
    LBRect frame;
} LBMoveCandidate;
typedef struct {
    uint32_t status, adjacent;
    double target_x, target_y, fallback_x, fallback_y;
} LBMovePlan;
typedef struct {
    uint64_t deadline, next_observation;
    uint32_t complete, reserved;
} LBFrameWait;
typedef struct {
    uint32_t active, attempt;
    uint64_t deadline;
} LBMoveLease;
LBMovePlan lb_plan_move(LBMoveCandidate, LBMoveCandidate, uint32_t, uint32_t);
LBFrameWait lb_frame_wait_start(uint64_t, uint64_t);
int64_t lb_frame_wait_poll(LBFrameWait *, uint64_t);
uint32_t lb_move_begin(LBMoveLease *, uint64_t);
uint32_t lb_move_attempt(LBMoveLease *, uint64_t);

uint32_t lb_interface_showing(uint32_t, uint32_t, int32_t);
uint32_t lb_restoration_allowed(uint64_t, uint64_t, uint32_t, uint32_t);
uint32_t lb_resolve_window(uint32_t, const uint32_t *, size_t);
uint32_t lb_store_journal(const uint8_t *, size_t, const uint8_t *, size_t);
#endif
