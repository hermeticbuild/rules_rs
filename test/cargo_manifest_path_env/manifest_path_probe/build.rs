use std::env;
use std::path::Path;

fn main() {
    let manifest_path = env::var("CARGO_MANIFEST_PATH")
        .expect("CARGO_MANIFEST_PATH should be available to build scripts");
    let manifest_path = Path::new(&manifest_path);

    assert!(
        manifest_path.is_file(),
        "CARGO_MANIFEST_PATH should point to a Cargo.toml file: {}",
        manifest_path.display(),
    );
    assert_eq!(
        manifest_path.file_name().and_then(|name| name.to_str()),
        Some("Cargo.toml"),
    );
}
