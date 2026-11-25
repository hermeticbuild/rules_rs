use std::{env, fs, path::Path};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let manifest_dir = env::var("CARGO_MANIFEST_DIR")?;
    let license_file = env::var("CARGO_PKG_LICENSE_FILE")?;
    let license = fs::read_to_string(Path::new(&manifest_dir).join(license_file))?;
    println!("cargo:rustc-env=INHERITED_LICENSE={}", license.trim());
    Ok(())
}
