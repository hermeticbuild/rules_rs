pub fn check() {}

pub fn build_target_os() -> &'static str {
    env!("BUILD_FEATURE_TARGET_OS")
}
