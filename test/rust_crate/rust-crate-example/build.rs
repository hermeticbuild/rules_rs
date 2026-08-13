mod build_support;

fn main() {
    println!(
        "cargo:rustc-env=RUST_CRATE_BUILD_VALUE={}",
        build_support::value()
    );
}
