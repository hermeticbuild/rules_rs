use std::ffi::c_void;

unsafe extern "C" {
    fn _Unwind_GetIP(ctx: *mut c_void) -> usize;
    fn _Unwind_GetIPInfo(ctx: *mut c_void, ip_before_insn: *mut i32) -> usize;
}

#[no_mangle]
pub extern "C" fn Java_com_example_FileWatcher_nativeInit() -> usize {
    let get_ip = _Unwind_GetIP as usize;
    let get_ip_info = _Unwind_GetIPInfo as usize;
    get_ip ^ get_ip_info
}
