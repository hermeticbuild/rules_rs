#[test]
fn detects_use_after_free() {
    let ptr = Box::into_raw(Box::new(123_u8));

    unsafe {
        drop(Box::from_raw(ptr));
        let _ = std::ptr::read(ptr);
    }
}
