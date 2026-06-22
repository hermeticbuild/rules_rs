#[cfg(all(feature = "exec_feature", feature = "target_feature"))]
compile_error!("target and exec features were unified");

#[cfg(feature = "exec_feature")]
pub fn exec_only() {}

#[cfg(feature = "target_feature")]
pub fn target_only() {}
