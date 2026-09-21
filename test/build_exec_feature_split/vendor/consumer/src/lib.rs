pub use feature_split_shared::target_only;

#[cfg(target_os = "linux")]
pub fn macro_check() {
    feature_split_macro::check!();
}
