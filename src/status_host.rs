use std::ffi::{c_char, c_void};

type Ref = *const c_void;

unsafe extern "C" {
    fn pthread_main_np() -> i32;
}

#[link(name = "objc")]
unsafe extern "C" {
    fn object_getClass(object: Ref) -> Ref;
    fn sel_registerName(name: *const c_char) -> Ref;
    fn class_getInstanceMethod(class: Ref, selector: Ref) -> Ref;
    fn method_getNumberOfArguments(method: Ref) -> u32;
    fn method_getTypeEncoding(method: Ref) -> *const c_char;
    fn method_getImplementation(method: Ref) -> *const c_void;
}

#[allow(clippy::missing_safety_doc)]
#[no_mangle]
pub unsafe extern "C" fn lb_status_item_window_id(object: Ref, local_number: i64) -> u32 {
    if unsafe { pthread_main_np() } == 0 {
        return 0;
    }
    let local = u32::try_from(local_number).unwrap_or(0);
    if object.is_null() {
        return local;
    }
    let selector = unsafe { sel_registerName(c"hostWindowID".as_ptr()) };
    let class = unsafe { object_getClass(object) };
    if class.is_null() {
        return 0;
    }
    let method = unsafe { class_getInstanceMethod(class, selector) };
    if method.is_null() {
        return local;
    }
    if unsafe { method_getNumberOfArguments(method) } != 2 {
        return 0;
    }
    let encoding = unsafe { method_getTypeEncoding(method) };
    let implementation = unsafe { method_getImplementation(method) };
    if encoding.is_null() || implementation.is_null() {
        return 0;
    }
    let id = match unsafe { *encoding as u8 } {
        b'I' => {
            let get: unsafe extern "C" fn(Ref, Ref) -> u32 =
                unsafe { std::mem::transmute(implementation) };
            u64::from(unsafe { get(object, selector) })
        }
        b'Q' => {
            let get: unsafe extern "C" fn(Ref, Ref) -> u64 =
                unsafe { std::mem::transmute(implementation) };
            unsafe { get(object, selector) }
        }
        b'i' => {
            let get: unsafe extern "C" fn(Ref, Ref) -> i32 =
                unsafe { std::mem::transmute(implementation) };
            u64::try_from(unsafe { get(object, selector) }).unwrap_or(0)
        }
        b'q' => {
            let get: unsafe extern "C" fn(Ref, Ref) -> i64 =
                unsafe { std::mem::transmute(implementation) };
            u64::try_from(unsafe { get(object, selector) }).unwrap_or(0)
        }
        _ => return 0,
    };
    u32::try_from(id).unwrap_or(0)
}
