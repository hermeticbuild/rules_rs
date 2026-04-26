#[cfg(not(miri))]
compile_error!("miri_proc_macro_test must run with cfg(miri)");

miri_proc_macro::make_miri_value!();

#[test]
fn uses_proc_macro_dependency() {
    assert_eq!(proc_macro_generated_value(), 7);
}
