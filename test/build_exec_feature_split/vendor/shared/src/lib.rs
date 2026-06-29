#[cfg(all(feature = "exec_feature", feature = "target_feature"))]
compile_error!("target and exec features were unified");

#[cfg(all(feature = "exec_feature", feature = "unannotated_proc_macro_feature"))]
compile_error!("unannotated proc-macro features entered exec resolution");

#[cfg(feature = "exec_feature")]
pub fn exec_only() {}

#[cfg(feature = "target_feature")]
pub fn target_only() {}

#[cfg(feature = "unannotated_proc_macro_feature")]
pub fn unannotated_proc_macro_only() {}
