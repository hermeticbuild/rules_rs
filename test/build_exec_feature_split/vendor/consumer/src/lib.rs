pub use feature_split_wrapper::target_only;

#[cfg(target_os = "linux")]
pub fn macro_check() {
    feature_split_macro::check!();
}
