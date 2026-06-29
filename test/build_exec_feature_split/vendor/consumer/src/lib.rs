#[feature_split_proc_macro::identity]
pub fn annotated_proc_macro() {}

#[feature_split_unannotated_proc_macro::identity]
pub fn unannotated_proc_macro() {}

pub use feature_split_shared::target_only;
