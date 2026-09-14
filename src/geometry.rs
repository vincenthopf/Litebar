#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    pub fn valid(self) -> bool {
        [
            self.x,
            self.y,
            self.width,
            self.height,
            self.x + self.width,
            self.y + self.height,
        ]
        .into_iter()
        .all(f64::is_finite)
    }

    pub fn min_x(self) -> f64 {
        self.x.min(self.x + self.width)
    }

    pub fn max_x(self) -> f64 {
        self.x.max(self.x + self.width)
    }

    pub fn min_y(self) -> f64 {
        self.y.min(self.y + self.height)
    }

    pub fn max_y(self) -> f64 {
        self.y.max(self.y + self.height)
    }

    pub fn contains(self, x: f64, y: f64) -> bool {
        self.valid()
            && x.is_finite()
            && y.is_finite()
            && x >= self.min_x()
            && x < self.max_x()
            && y >= self.min_y()
            && y < self.max_y()
    }
}

#[repr(u32)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Section {
    Visible = 1,
    Hidden = 2,
    AlwaysHidden = 4,
}

pub fn section_mask(item: Rect, hidden: Rect, always: Option<Rect>) -> u32 {
    if !item.valid() || !hidden.valid() || always.is_some_and(|rect| !rect.valid()) {
        return 0;
    }
    let visible = item.min_x() >= hidden.max_x();
    let concealed =
        item.max_x() <= hidden.min_x() && always.is_none_or(|rect| item.min_x() >= rect.max_x());
    let permanent = always.is_some_and(|rect| item.max_x() <= rect.min_x());
    u32::from(visible) | (u32::from(concealed) << 1) | (u32::from(permanent) << 2)
}

pub fn classify(item: Rect, hidden: Rect, always: Option<Rect>) -> Option<Section> {
    let mask = section_mask(item, hidden, always);
    [Section::Visible, Section::Hidden, Section::AlwaysHidden]
        .into_iter()
        .find(|section| mask & (*section as u32) != 0)
}

pub fn appkit_to_quartz(rect: Rect, primary_top: f64) -> Option<Rect> {
    if !rect.valid() || !primary_top.is_finite() {
        return None;
    }
    let result = Rect {
        x: rect.min_x(),
        y: primary_top - rect.max_y(),
        width: rect.width.abs(),
        height: rect.height.abs(),
    };
    result.valid().then_some(result)
}

pub fn same_menu_item(window: Rect, element: Rect) -> bool {
    window.valid()
        && element.valid()
        && window.width > 0.0
        && window.height > 0.0
        && element.width > 0.0
        && element.height > 0.0
        && window.contains(
            element.x + element.width / 2.0,
            element.y + element.height / 2.0,
        )
        && element.contains(
            window.x + window.width / 2.0,
            window.y + window.height / 2.0,
        )
}
