fn main() {
    feature_split_shared::exec_only();
    println!(
        "cargo:rustc-env=BUILD_FEATURE_TARGET_OS={}",
        feature_split_shared::build_target_os()
    );
}
