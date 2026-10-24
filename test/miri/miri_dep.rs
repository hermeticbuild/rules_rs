miri_proc_macro::make_miri_value!();

pub fn value_from_miri_dep() -> i32 {
    assert_eq!(proc_macro_generated_value(), 7);
    miri_leaf::leaf_value() + 1
}
