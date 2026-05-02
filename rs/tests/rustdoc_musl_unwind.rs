//! ```
//! assert_eq!(rustdoc_musl_unwind::unwind_value(), 430);
//! ```

extern "C" {
    fn rustdoc_musl_unwind_value() -> i32;
}

pub fn unwind_value() -> i32 {
    unsafe { rustdoc_musl_unwind_value() }
}
