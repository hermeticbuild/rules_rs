//! Enumerates mutants for a single Bazel crate using `cargo-mutants --list --json`.
//!
//! cargo-mutants is cargo-only, but `--list` only needs `cargo metadata` to find
//! the source files and then syn-parses them, so a synthetic dependency-free
//! manifest is enough. Sources are copied to `<tmp>/src/<exec path>` so the
//! `file` fields in the emitted JSON are the crate's Bazel paths with a `src/`
//! prefix; `cargo_mutants_runner` strips that prefix back off.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

struct Args {
    cargo_mutants: PathBuf,
    cargo: PathBuf,
    crate_name: String,
    edition: String,
    crate_root: PathBuf,
    output: PathBuf,
    srcs: Vec<PathBuf>,
}

fn parse_args() -> Result<Args, String> {
    let mut cargo_mutants = None;
    let mut cargo = None;
    let mut crate_name = None;
    let mut edition = None;
    let mut crate_root = None;
    let mut output = None;
    let mut srcs = Vec::new();

    let mut argv = env::args().skip(1);
    while let Some(flag) = argv.next() {
        let value = argv
            .next()
            .ok_or_else(|| format!("missing value for {flag}"))?;
        match flag.as_str() {
            "--cargo-mutants" => cargo_mutants = Some(PathBuf::from(value)),
            "--cargo" => cargo = Some(PathBuf::from(value)),
            "--crate-name" => crate_name = Some(value),
            "--edition" => edition = Some(value),
            "--crate-root" => crate_root = Some(PathBuf::from(value)),
            "--output" => output = Some(PathBuf::from(value)),
            "--src" => srcs.push(PathBuf::from(value)),
            other => return Err(format!("unknown flag {other}")),
        }
    }

    Ok(Args {
        cargo_mutants: cargo_mutants.ok_or("missing --cargo-mutants")?,
        cargo: cargo.ok_or("missing --cargo")?,
        crate_name: crate_name.ok_or("missing --crate-name")?,
        edition: edition.ok_or("missing --edition")?,
        crate_root: crate_root.ok_or("missing --crate-root")?,
        output: output.ok_or("missing --output")?,
        srcs,
    })
}

fn absolute(path: &Path) -> Result<PathBuf, String> {
    path.canonicalize()
        .map_err(|err| format!("failed to resolve {}: {err}", path.display()))
}

fn copy_into(root: &Path, src: &Path) -> Result<(), String> {
    let dest = root.join("src").join(src);
    if let Some(parent) = dest.parent() {
        fs::create_dir_all(parent)
            .map_err(|err| format!("failed to create {}: {err}", parent.display()))?;
    }
    fs::copy(src, &dest).map(|_| ()).map_err(|err| {
        format!(
            "failed to copy {} to {}: {err}",
            src.display(),
            dest.display()
        )
    })
}

fn write_manifest(root: &Path, args: &Args) -> Result<(), String> {
    // `[workspace]` stops cargo walking up into whatever encloses the temp dir.
    let manifest = format!(
        "[workspace]\n\n\
         [package]\n\
         name = \"{name}\"\n\
         version = \"0.0.0\"\n\
         edition = \"{edition}\"\n\n\
         [lib]\n\
         name = \"{name}\"\n\
         path = \"src/{root_path}\"\n\
         doctest = false\n\n\
         [dependencies]\n",
        name = args.crate_name,
        edition = args.edition,
        root_path = args.crate_root.display(),
    );
    let path = root.join("Cargo.toml");
    fs::write(&path, manifest).map_err(|err| format!("failed to write {}: {err}", path.display()))
}

fn run() -> Result<(), String> {
    let args = parse_args()?;
    let cargo_mutants = absolute(&args.cargo_mutants)?;
    let cargo = absolute(&args.cargo)?;
    let cargo_bin = cargo
        .parent()
        .ok_or_else(|| format!("cargo has no parent directory: {}", cargo.display()))?;

    let root = env::temp_dir().join(format!(
        "cargo_mutants_list.{}.{}",
        args.crate_name,
        std::process::id()
    ));
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(&root)
        .map_err(|err| format!("failed to create {}: {err}", root.display()))?;

    for src in &args.srcs {
        copy_into(&root, src)?;
    }
    copy_into(&root, &args.crate_root)?;
    write_manifest(&root, &args)?;

    let path = match env::var_os("PATH") {
        Some(existing) => env::join_paths(
            std::iter::once(cargo_bin.to_path_buf()).chain(env::split_paths(&existing)),
        )
        .map_err(|err| format!("failed to build PATH: {err}"))?,
        None => cargo_bin.into(),
    };

    // The `mutants` token is required: cargo-mutants' CLI is declared with
    // bin_name = "cargo", so it expects to be invoked as `cargo mutants`.
    let out = Command::new(&cargo_mutants)
        .args(["mutants", "--list", "--json"])
        .current_dir(&root)
        .env("CARGO", &cargo)
        .env("PATH", path)
        .env("CARGO_HOME", root.join("cargo_home"))
        .env("CARGO_TARGET_DIR", root.join("target"))
        .env("CARGO_NET_OFFLINE", "true")
        .output()
        .map_err(|err| format!("failed to run {}: {err}", cargo_mutants.display()))?;

    if !out.status.success() {
        return Err(format!(
            "cargo-mutants --list failed ({}):\n{}",
            out.status,
            String::from_utf8_lossy(&out.stderr)
        ));
    }

    fs::write(&args.output, &out.stdout)
        .map_err(|err| format!("failed to write {}: {err}", args.output.display()))?;
    let _ = fs::remove_dir_all(&root);
    Ok(())
}

fn main() {
    if let Err(err) = run() {
        eprintln!("mutants_list: {err}");
        std::process::exit(1);
    }
}
