#![allow(clippy::missing_safety_doc)]

use crate::geometry::Rect;
use std::cell::OnceCell;
use std::ffi::{c_char, c_void, CStr};
use std::ptr;

type Ref = *const c_void;
type Connection = unsafe extern "C" fn() -> i32;
type Count = unsafe extern "C" fn(i32, i32, *mut i32) -> i32;
type List = unsafe extern "C" fn(i32, i32, i32, *mut u32, *mut i32) -> i32;
type ActiveSpace = unsafe extern "C" fn(i32) -> usize;
type SpaceType = unsafe extern "C" fn(i32, usize) -> u32;
type Spaces = unsafe extern "C" fn(i32, u32, Ref) -> Ref;
type CopyProperty = unsafe extern "C" fn(i32, i32, Ref, *mut Ref) -> i32;
type SetProperty = unsafe extern "C" fn(i32, i32, Ref, Ref) -> i32;
type Unresponsive = unsafe extern "C" fn(i32, *mut ProcessSerialNumber) -> bool;

#[repr(C)]
struct ProcessSerialNumber {
    high: u32,
    low: u32,
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFArrayCreate(allocator: Ref, values: *const Ref, count: isize, callbacks: Ref) -> Ref;
    fn CFArrayGetCount(array: Ref) -> isize;
    fn CFArrayGetValueAtIndex(array: Ref, index: isize) -> Ref;
    fn CFArrayGetTypeID() -> usize;
    fn CFDictionaryGetTypeID() -> usize;
    fn CFDictionaryGetValue(dictionary: Ref, key: Ref) -> Ref;
    fn CFNumberCreate(allocator: Ref, kind: i32, value: Ref) -> Ref;
    fn CFNumberGetValue(number: Ref, kind: i32, value: *mut c_void) -> bool;
    fn CFNumberGetTypeID() -> usize;
    fn CFStringCreateWithCString(allocator: Ref, string: *const c_char, encoding: u32) -> Ref;
    fn CFBooleanGetTypeID() -> usize;
    fn CFBooleanGetValue(value: Ref) -> bool;
    fn CFGetTypeID(value: Ref) -> usize;
    fn CFRelease(value: Ref);
    static kCFTypeArrayCallBacks: u8;
    static kCFBooleanTrue: Ref;
    static kCFBooleanFalse: Ref;
}

#[link(name = "CoreGraphics", kind = "framework")]
unsafe extern "C" {
    fn CGWindowListCreateDescriptionFromArray(array: Ref) -> Ref;
    fn CGRectMakeWithDictionaryRepresentation(dictionary: Ref, rect: *mut Rect) -> bool;
    static kCGWindowBounds: Ref;
}

#[link(name = "Carbon", kind = "framework")]
unsafe extern "C" {
    fn GetProcessForPID(pid: i32, serial: *mut ProcessSerialNumber) -> i32;
}

unsafe extern "C" {
    fn dlopen(path: *const c_char, mode: i32) -> *mut c_void;
    fn dlsym(handle: *mut c_void, symbol: *const c_char) -> *mut c_void;
    fn dlclose(handle: *mut c_void) -> i32;
    fn pthread_main_np() -> i32;
}

struct Owned(Ref);

impl Owned {
    fn new(value: Ref) -> Option<Self> {
        (!value.is_null()).then_some(Self(value))
    }
}

impl Drop for Owned {
    fn drop(&mut self) {
        unsafe { CFRelease(self.0) }
    }
}

struct Api {
    handle: *mut c_void,
    connection: Option<Connection>,
    count: Option<Count>,
    list: Option<List>,
    active: Option<ActiveSpace>,
    kind: Option<SpaceType>,
    spaces: Option<Spaces>,
    copy: Option<CopyProperty>,
    set: Option<SetProperty>,
    unresponsive: Option<Unresponsive>,
}

impl Api {
    fn new() -> Self {
        let handle = unsafe {
            dlopen(
                c"/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight".as_ptr(),
                5,
            )
        };
        let find = |first: &CStr, second: &CStr| {
            if handle.is_null() {
                return None;
            }
            let first = unsafe { dlsym(handle, first.as_ptr()) };
            let found = if first.is_null() {
                unsafe { dlsym(handle, second.as_ptr()) }
            } else {
                first
            };
            (!found.is_null()).then_some(found)
        };
        macro_rules! symbol {
            ($ty:ty, $first:expr, $second:expr) => {
                find($first, $second)
                    .map(|raw| unsafe { std::mem::transmute::<*mut c_void, $ty>(raw) })
            };
        }
        Self {
            handle,
            connection: symbol!(Connection, c"CGSMainConnectionID", c"SLSMainConnectionID"),
            count: symbol!(Count, c"CGSGetWindowCount", c"SLSGetWindowCount"),
            list: symbol!(
                List,
                c"CGSGetProcessMenuBarWindowList",
                c"SLSGetProcessMenuBarWindowList"
            ),
            active: symbol!(ActiveSpace, c"CGSGetActiveSpace", c"SLSGetActiveSpace"),
            kind: symbol!(SpaceType, c"CGSSpaceGetType", c"SLSSpaceGetType"),
            spaces: symbol!(
                Spaces,
                c"CGSCopySpacesForWindows",
                c"SLSCopySpacesForWindows"
            ),
            copy: symbol!(
                CopyProperty,
                c"CGSCopyConnectionProperty",
                c"SLSCopyConnectionProperty"
            ),
            set: symbol!(
                SetProperty,
                c"CGSSetConnectionProperty",
                c"SLSSetConnectionProperty"
            ),
            unresponsive: symbol!(
                Unresponsive,
                c"CGSEventIsAppUnresponsive",
                c"SLSEventIsAppUnresponsive"
            ),
        }
    }

    fn available(&self) -> bool {
        self.connection.is_some()
            && self.count.is_some()
            && self.list.is_some()
            && self.active.is_some()
            && self.spaces.is_some()
    }

    fn connection(&self) -> Option<i32> {
        self.connection.map(|call| unsafe { call() })
    }

    fn active_space(&self) -> Option<usize> {
        let value = unsafe { (self.active?)(self.connection()?) };
        (value != 0).then_some(value)
    }

    fn on_space(&self, id: u32, space: usize) -> Option<bool> {
        let number = i64::from(id);
        let number =
            Owned::new(unsafe { CFNumberCreate(ptr::null(), 4, ptr::from_ref(&number).cast()) })?;
        let array = Owned::new(unsafe {
            CFArrayCreate(
                ptr::null(),
                &number.0,
                1,
                ptr::addr_of!(kCFTypeArrayCallBacks).cast(),
            )
        })?;
        let values = Owned::new(unsafe { (self.spaces?)(self.connection()?, 7, array.0) })?;
        if unsafe { CFGetTypeID(values.0) != CFArrayGetTypeID() } {
            return None;
        }
        let count = unsafe { CFArrayGetCount(values.0) };
        if !(0..=4096).contains(&count) {
            return None;
        }
        for index in 0..count {
            let value = unsafe { CFArrayGetValueAtIndex(values.0, index) };
            if value.is_null() || unsafe { CFGetTypeID(value) != CFNumberGetTypeID() } {
                return None;
            }
            let mut result = 0i64;
            if !unsafe { CFNumberGetValue(value, 4, ptr::from_mut(&mut result).cast()) } {
                return None;
            }
            if result > 0 && result as usize == space {
                return Some(true);
            }
        }
        Some(false)
    }

    fn descriptions(&self) -> Option<Ref> {
        let connection = self.connection()?;
        let active = self.active_space()?;
        let mut capacity = 0i32;
        if unsafe { (self.count?)(connection, 0, &mut capacity) } != 0
            || !(0..=65536).contains(&capacity)
        {
            return None;
        }
        capacity = (capacity + 64).min(65536);
        let mut ids = vec![0u32; capacity as usize];
        let mut actual = 0i32;
        if unsafe { (self.list?)(connection, 0, capacity, ids.as_mut_ptr(), &mut actual) } != 0
            || !(0..capacity).contains(&actual)
        {
            return None;
        }
        ids.truncate(actual as usize);
        let mut values = Vec::with_capacity(ids.len());
        for id in ids {
            if id != 0 && self.on_space(id, active)? {
                values.push(id as usize as Ref);
            }
        }
        let array = Owned::new(unsafe {
            CFArrayCreate(
                ptr::null(),
                values.as_ptr(),
                values.len() as isize,
                ptr::null(),
            )
        })?;
        let result = Owned::new(unsafe { CGWindowListCreateDescriptionFromArray(array.0) })?;
        if self.active_space()? != active {
            return None;
        }
        let raw = result.0;
        std::mem::forget(result);
        Some(raw)
    }

    fn cursor_key(&self) -> Option<Owned> {
        Owned::new(unsafe {
            CFStringCreateWithCString(ptr::null(), c"SetsCursorInBackground".as_ptr(), 0x08000100)
        })
    }
}

impl Drop for Api {
    fn drop(&mut self) {
        if !self.handle.is_null() {
            unsafe { dlclose(self.handle) };
        }
    }
}

thread_local! {
    static API: OnceCell<Api> = const { OnceCell::new() };
}

fn with_api<T>(fallback: T, action: impl FnOnce(&Api) -> Option<T>) -> T {
    if unsafe { pthread_main_np() } == 0 {
        return fallback;
    }
    API.with(|api| action(api.get_or_init(Api::new)))
        .unwrap_or(fallback)
}

#[no_mangle]
pub extern "C" fn lb_window_server_available() -> u32 {
    with_api(0, |api| Some(u32::from(api.available())))
}

#[no_mangle]
pub extern "C" fn lb_active_space() -> u64 {
    with_api(0, |api| api.active_space().map(|space| space as u64))
}

#[no_mangle]
pub extern "C" fn lb_fullscreen() -> u32 {
    with_api(0, |api| {
        Some(u32::from(
            unsafe { (api.kind?)(api.connection()?, api.active_space()?) } == 4,
        ))
    })
}

#[no_mangle]
pub unsafe extern "C" fn lb_window_frame(id: u32, output: *mut Rect) -> u32 {
    if output.is_null() || id == 0 {
        return 0;
    }
    if unsafe { pthread_main_np() } == 0 {
        return 0;
    }
    let value = id as usize as Ref;
    let Some(array) = Owned::new(unsafe { CFArrayCreate(ptr::null(), &value, 1, ptr::null()) })
    else {
        return 0;
    };
    let Some(descriptions) = Owned::new(unsafe { CGWindowListCreateDescriptionFromArray(array.0) })
    else {
        return 0;
    };
    if unsafe {
        CFGetTypeID(descriptions.0) != CFArrayGetTypeID() || CFArrayGetCount(descriptions.0) != 1
    } {
        return 0;
    }
    let dictionary = unsafe { CFArrayGetValueAtIndex(descriptions.0, 0) };
    if dictionary.is_null() || unsafe { CFGetTypeID(dictionary) != CFDictionaryGetTypeID() } {
        return 0;
    }
    let bounds = unsafe { CFDictionaryGetValue(dictionary, kCGWindowBounds) };
    if bounds.is_null() || unsafe { CFGetTypeID(bounds) != CFDictionaryGetTypeID() } {
        return 0;
    }
    let mut frame = Rect::default();
    if !unsafe { CGRectMakeWithDictionaryRepresentation(bounds, &mut frame) }
        || !frame.valid()
        || frame.width < 0.0
        || frame.height < 0.0
    {
        return 0;
    }
    unsafe { output.write(frame) };
    1
}

#[no_mangle]
pub extern "C" fn lb_copy_window_descriptions() -> Ref {
    with_api(ptr::null(), Api::descriptions)
}

#[no_mangle]
pub extern "C" fn lb_cursor_property() -> i32 {
    with_api(-1, |api| {
        let connection = api.connection()?;
        let key = api.cursor_key()?;
        let mut raw = ptr::null();
        let status = unsafe { (api.copy?)(connection, connection, key.0, &mut raw) };
        let value = Owned::new(raw)?;
        if status != 0 || unsafe { CFGetTypeID(value.0) != CFBooleanGetTypeID() } {
            return None;
        }
        Some(i32::from(unsafe { CFBooleanGetValue(value.0) }))
    })
}

#[no_mangle]
pub extern "C" fn lb_set_cursor_property(enabled: u32) -> u32 {
    with_api(0, |api| {
        let connection = api.connection()?;
        let key = api.cursor_key()?;
        let value = unsafe {
            if enabled == 0 {
                kCFBooleanFalse
            } else {
                kCFBooleanTrue
            }
        };
        Some(u32::from(
            unsafe { (api.set?)(connection, connection, key.0, value) } == 0,
        ))
    })
}

#[no_mangle]
pub extern "C" fn lb_process_responsivity(pid: i32) -> i32 {
    with_api(0, |api| {
        let mut serial = ProcessSerialNumber { high: 0, low: 0 };
        if pid <= 0 || unsafe { GetProcessForPID(pid, &mut serial) } != 0 {
            return None;
        }
        Some(
            if unsafe { (api.unresponsive?)(api.connection()?, &mut serial) } {
                -1
            } else {
                1
            },
        )
    })
}
