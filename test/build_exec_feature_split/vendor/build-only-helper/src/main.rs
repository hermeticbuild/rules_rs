#[cfg(all(target_os = "linux", not(feature = "binary_linux")))]
compile_error!("generated binaries must receive platform-specific annotated features");

fn main() {
    build_only_helper::build_target_os();
}
