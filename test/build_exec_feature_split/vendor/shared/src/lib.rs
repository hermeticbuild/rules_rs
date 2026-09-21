#[cfg(all(feature = "exec_feature", feature = "target_feature"))]
compile_error!("target and exec features were unified");

#[cfg(all(feature = "linux_build", feature = "darwin_build"))]
compile_error!("build-dependency features from different target platforms were unified");

#[cfg(feature = "exec_feature")]
pub fn exec_only() {}

#[cfg(feature = "target_feature")]
pub fn target_only() {}

pub fn build_target_os() -> &'static str {
    if cfg!(feature = "linux_build") {
        "linux"
    } else if cfg!(feature = "darwin_build") {
        "macos"
    } else {
        "other"
    }
}
