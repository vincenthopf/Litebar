pub const HOVER: u32 = 1;
pub const CLICK: u32 = 2;
pub const SCROLL: u32 = 4;
pub const AUTO_REHIDE: u32 = 8;
pub const ALWAYS_ENABLED: u32 = 16;
pub const SEPARATE_PANEL: u32 = 32;
pub const SHOW_DIVIDERS: u32 = 64;
pub const KNOWN_FLAGS: u32 = 127;
pub const SMART: u32 = 0;
pub const TIMED: u32 = 1;
pub const FOCUSED_APP: u32 = 2;

pub const TOGGLE_HIDDEN: u32 = 1;
pub const TOGGLE_ALWAYS: u32 = 2;
pub const HIDE_ALL: u32 = 3;
pub const POINTER_EMPTY: u32 = 4;
pub const POINTER_BAR: u32 = 5;
pub const POINTER_OUTSIDE: u32 = 6;
pub const CLICK_EMPTY: u32 = 7;
pub const SCROLL_SHOW: u32 = 8;
pub const SCROLL_HIDE: u32 = 9;
pub const DEADLINE: u32 = 10;
pub const FOCUS_CHANGED: u32 = 11;
pub const MENU_BEGIN: u32 = 12;
pub const MENU_END: u32 = 13;
pub const BUTTON_DOWN: u32 = 14;
pub const BUTTON_UP: u32 = 15;
pub const SUSPEND: u32 = 16;
pub const RESUME: u32 = 17;
pub const SHOW_HIDDEN: u32 = 18;
pub const SHOW_ALWAYS: u32 = 19;
pub const SMART_REHIDE: u32 = 20;

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Config {
    pub flags: u32,
    pub rehide_strategy: u32,
    pub rehide_ms: u64,
    pub hover_ms: u64,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            flags: CLICK | SCROLL | AUTO_REHIDE,
            rehide_strategy: 0,
            rehide_ms: 15000,
            hover_ms: 200,
        }
    }
}

impl Config {
    pub fn normalized(self) -> Self {
        Self {
            flags: self.flags & KNOWN_FLAGS,
            rehide_strategy: self.rehide_strategy.min(2),
            rehide_ms: self.rehide_ms.clamp(100, 3600000),
            hover_ms: self.hover_ms.min(10000),
        }
    }

    pub fn enabled(self, flag: u32) -> bool {
        self.flags & flag != 0
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct State {
    pub revealed: u32,
    pub panel: u32,
    pub pointer: u32,
    pub buttons: u32,
    pub tracking: u32,
    pub hover_blocked: u32,
    pub suspended: u32,
    pub reserved: u32,
    pub hover_deadline: u64,
    pub rehide_deadline: u64,
    pub last_time: u64,
}

impl State {
    pub fn any_visible(self) -> bool {
        self.revealed != 0 || self.panel != 0
    }

    pub fn hidden_visible(self) -> bool {
        self.revealed & 1 != 0 || self.panel == 1
    }

    pub fn always_visible(self) -> bool {
        self.revealed & 2 != 0 || self.panel == 2
    }

    pub fn next_deadline(self) -> u64 {
        match (self.hover_deadline, self.rehide_deadline) {
            (0, other) | (other, 0) => other,
            (first, second) => first.min(second),
        }
    }

    pub fn lengths(self, config: Config) -> (f64, f64) {
        let narrow = if config.enabled(SHOW_DIVIDERS) { 20.0 } else { 1.0 };
        (
            if self.revealed & 1 != 0 { narrow } else { 10000.0 },
            if !config.enabled(ALWAYS_ENABLED) {
                0.0
            } else if self.revealed & 2 != 0 {
                narrow
            } else {
                10000.0
            },
        )
    }

    fn hide_all(&mut self) {
        self.revealed = 0;
        self.panel = 0;
        self.hover_deadline = 0;
        self.rehide_deadline = 0;
        self.hover_blocked = u32::from(self.pointer != 0);
    }

    fn blocked(self) -> bool {
        self.buttons != 0 || self.tracking != 0 || self.suspended != 0
    }

    fn arm_rehide(&mut self, config: Config, now: u64) {
        self.rehide_deadline = 0;
        if self.any_visible() && self.pointer == 0 && !self.blocked()
            && config.enabled(AUTO_REHIDE) && config.rehide_strategy == TIMED
        {
            self.rehide_deadline = now.saturating_add(config.rehide_ms);
        }
    }

    fn show(&mut self, section: u32, config: Config, now: u64) {
        if section == 2 && !config.enabled(ALWAYS_ENABLED) {
            return;
        }
        self.hover_deadline = 0;
        if config.enabled(SEPARATE_PANEL) {
            self.panel = section;
            self.revealed = 0;
        } else {
            self.panel = 0;
            self.revealed = crate::events::classic_transition(self.revealed, section, 0);
        }
        self.arm_rehide(config, now);
    }

    pub fn reconfigure(mut self, config: Config, now: u64) -> Self {
        let config = config.normalized();
        let now = now.max(self.last_time).max(1);
        self.last_time = now;
        self.revealed &= 3;
        self.panel = self.panel.min(2);
        if !config.enabled(ALWAYS_ENABLED) {
            self.revealed &= 1;
            if self.panel == 2 {
                self.panel = 0;
            }
        }
        if self.any_visible() {
            let section = if self.always_visible() { 2 } else { 1 };
            self.revealed = 0;
            self.panel = 0;
            self.show(section, config, now);
        }
        self.hover_deadline = 0;
        self.arm_rehide(config, now);
        self
    }

    pub fn step(mut self, config: Config, event: u32, now: u64) -> Self {
        let config = config.normalized();
        let now = now.max(self.last_time).max(1);
        self.last_time = now;
        if event == SUSPEND {
            self.hide_all();
            self.suspended = 1;
            return self;
        }
        if event == RESUME {
            self.suspended = 0;
            self.pointer = 0;
            self.buttons = 0;
            self.tracking = 0;
            self.hover_blocked = 0;
            self.hover_deadline = 0;
            self.rehide_deadline = 0;
            self.arm_rehide(config, now);
            return self;
        }
        if self.suspended != 0 {
            return self;
        }
        match event {
            TOGGLE_HIDDEN => {
                if self.hidden_visible() {
                    self.hide_all();
                } else {
                    self.show(1, config, now);
                }
            }
            TOGGLE_ALWAYS if config.enabled(ALWAYS_ENABLED) => {
                if self.always_visible() {
                    if self.panel != 0 {
                        self.hide_all();
                    } else {
                        self.revealed &= !2;
                        self.arm_rehide(config, now);
                    }
                } else {
                    self.show(2, config, now);
                }
            }
            HIDE_ALL => self.hide_all(),
            SHOW_HIDDEN => self.show(1, config, now),
            SHOW_ALWAYS => self.show(2, config, now),
            POINTER_EMPTY | POINTER_BAR => {
                let pointer = if event == POINTER_EMPTY { 2 } else { 1 };
                let changed = self.pointer != pointer;
                self.pointer = pointer;
                self.rehide_deadline = 0;
                if event == POINTER_EMPTY && changed && config.enabled(HOVER)
                    && !self.any_visible() && !self.blocked() && self.hover_blocked == 0
                {
                    self.hover_deadline = now.saturating_add(config.hover_ms);
                } else if event == POINTER_BAR || self.any_visible() {
                    self.hover_deadline = 0;
                }
            }
            POINTER_OUTSIDE => {
                let changed = self.pointer != 0;
                self.pointer = 0;
                self.hover_blocked = 0;
                if changed {
                    self.hover_deadline = 0;
                    if config.enabled(HOVER) && self.any_visible() && !self.blocked() {
                        self.hover_deadline = now.saturating_add(config.hover_ms);
                    }
                    self.arm_rehide(config, now);
                }
            }
            CLICK_EMPTY if config.enabled(CLICK) && self.pointer == 2 => {
                if self.hidden_visible() {
                    self.hide_all();
                } else {
                    self.show(1, config, now);
                }
                self.hover_blocked = 1;
            }
            SCROLL_SHOW if config.enabled(SCROLL) && self.pointer != 0 => self.show(1, config, now),
            SCROLL_HIDE if config.enabled(SCROLL) && self.pointer != 0 => self.hide_all(),
            FOCUS_CHANGED | SMART_REHIDE
                if config.enabled(AUTO_REHIDE) && !self.blocked() && self.pointer == 0
                    && ((event == FOCUS_CHANGED && config.rehide_strategy == FOCUSED_APP)
                        || (event == SMART_REHIDE && config.rehide_strategy == SMART)) =>
            {
                self.hide_all();
            }
            MENU_BEGIN => {
                self.tracking = self.tracking.saturating_add(1);
                self.hover_deadline = 0;
                self.rehide_deadline = 0;
            }
            MENU_END => {
                self.tracking = self.tracking.saturating_sub(1);
                self.arm_rehide(config, now);
            }
            BUTTON_DOWN => {
                self.buttons = self.buttons.saturating_add(1);
                self.hover_deadline = 0;
                self.rehide_deadline = 0;
            }
            BUTTON_UP => {
                self.buttons = self.buttons.saturating_sub(1);
                self.arm_rehide(config, now);
            }
            DEADLINE => {
                if self.blocked() {
                    self.hover_deadline = 0;
                    self.rehide_deadline = 0;
                    return self;
                }
                if self.hover_deadline != 0 && now >= self.hover_deadline {
                    self.hover_deadline = 0;
                    if self.pointer == 2 && !self.any_visible() && self.hover_blocked == 0 {
                        self.show(1, config, now);
                    } else if self.pointer == 0 && self.any_visible() {
                        self.hide_all();
                    }
                }
                if self.rehide_deadline != 0 && now >= self.rehide_deadline {
                    self.rehide_deadline = 0;
                    if self.pointer == 0 {
                        self.hide_all();
                    }
                }
            }
            _ => {}
        }
        self
    }
}
