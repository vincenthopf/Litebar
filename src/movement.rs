use crate::geometry::{Rect, Section};
use crate::identity::Identity;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Side {
    Left,
    Right,
}

#[derive(Clone, Copy, Debug)]
pub struct Item<'a> {
    pub window_id: u32,
    pub process_id: i32,
    pub display_id: u32,
    pub identity: Identity<'a>,
    pub frame: Rect,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MoveError {
    InvalidItem,
    SameItem,
    DifferentDisplay,
    ProtectedItem,
    CannotHide,
    Busy,
    TimedOut,
    Failed,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Plan {
    pub source_window: u32,
    pub target_window: u32,
    pub source_pid: i32,
    pub target_pid: i32,
    pub target_point: (f64, f64),
    pub fallback_point: (f64, f64),
    pub already_adjacent: bool,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Candidate {
    pub window_id: u32,
    pub process_id: i32,
    pub display_id: u32,
    pub flags: u32,
    pub frame: Rect,
}

impl From<Item<'_>> for Candidate {
    fn from(item: Item<'_>) -> Self {
        Self {
            window_id: item.window_id,
            process_id: item.process_id,
            display_id: item.display_id,
            flags: u32::from(item.identity.movable()) | (u32::from(item.identity.hideable()) << 1),
            frame: item.frame,
        }
    }
}

pub fn plan(
    source: Item<'_>,
    target: Item<'_>,
    side: Side,
    section: Section,
) -> Result<Plan, MoveError> {
    plan_candidates(source.into(), target.into(), side, section)
}

pub fn plan_candidates(
    source: Candidate,
    target: Candidate,
    side: Side,
    section: Section,
) -> Result<Plan, MoveError> {
    if source.window_id == 0
        || target.window_id == 0
        || source.process_id <= 0
        || target.process_id <= 0
        || !source.frame.valid()
        || !target.frame.valid()
        || source.frame.width <= 0.0
        || source.frame.height <= 0.0
        || target.frame.width < 0.0
        || target.frame.height <= 0.0
    {
        return Err(MoveError::InvalidItem);
    }
    if source.window_id == target.window_id {
        return Err(MoveError::SameItem);
    }
    if source.display_id == 0
        || source.display_id != target.display_id
        || (source.frame.y + source.frame.height / 2.0 - target.frame.y - target.frame.height / 2.0)
            .abs()
            >= 2.0
    {
        return Err(MoveError::DifferentDisplay);
    }
    if source.flags & 1 == 0 {
        return Err(MoveError::ProtectedItem);
    }
    if section != Section::Visible && source.flags & 2 == 0 {
        return Err(MoveError::CannotHide);
    }
    let edge = match side {
        Side::Left => target.frame.min_x(),
        Side::Right => target.frame.max_x(),
    };
    let adjacent = match side {
        Side::Left => (source.frame.max_x() - target.frame.min_x()).abs() < 1.0,
        Side::Right => (source.frame.min_x() - target.frame.max_x()).abs() < 1.0,
    };
    Ok(Plan {
        source_window: source.window_id,
        target_window: target.window_id,
        source_pid: source.process_id,
        target_pid: target.process_id,
        target_point: (edge, target.frame.y + target.frame.height / 2.0),
        fallback_point: (
            source.frame.x + source.frame.width / 2.0,
            source.frame.y + source.frame.height / 2.0,
        ),
        already_adjacent: adjacent,
    })
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Poll {
    WaitUntil(u64),
    ObserveFrame,
    Complete,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct FrameWait {
    deadline: u64,
    next_observation: u64,
    complete: u32,
    reserved: u32,
}

impl FrameWait {
    pub fn new(now: u64, timeout_ms: u64) -> Self {
        Self {
            deadline: now.saturating_add(timeout_ms.clamp(1, 1000)),
            next_observation: now,
            complete: 0,
            reserved: 0,
        }
    }

    pub fn poll(&mut self, now: u64) -> Result<Poll, MoveError> {
        if self.complete != 0 {
            return Ok(Poll::Complete);
        }
        if now >= self.deadline {
            return Err(MoveError::TimedOut);
        }
        if now < self.next_observation {
            return Ok(Poll::WaitUntil(self.next_observation));
        }
        self.next_observation = now.saturating_add(10).min(self.deadline);
        Ok(Poll::ObserveFrame)
    }

    pub fn observe(&mut self, changed: bool) {
        self.complete |= u32::from(changed);
    }
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct MoveLease {
    active: u32,
    attempt: u32,
    deadline: u64,
}

impl MoveLease {
    pub fn begin(&mut self, now: u64) -> Result<(), MoveError> {
        if self.active != 0 {
            return Err(MoveError::Busy);
        }
        self.active = 1;
        self.attempt = 0;
        self.deadline = now.saturating_add(2000);
        Ok(())
    }

    pub fn next_attempt(&mut self, now: u64) -> Result<u32, MoveError> {
        if self.active == 0 {
            return Err(MoveError::Failed);
        }
        if now >= self.deadline {
            return Err(MoveError::TimedOut);
        }
        if self.attempt >= 5 {
            return Err(MoveError::Failed);
        }
        self.attempt += 1;
        Ok(self.attempt)
    }

    pub fn finish(&mut self) {
        *self = Self::default();
    }
}
