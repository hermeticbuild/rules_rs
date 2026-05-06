//! Small execution wrapper for Bazel-native Dylint actions.
//!
//! `dylint-driver` expects library selection and optional configuration through
//! environment variables. Keeping that translation in a tiny compiled helper lets the
//! Starlark rule stay hermetic while still supporting configuration files on Linux,
//! macOS, and Windows.

use std::{
    env,
    ffi::OsString,
    fs,
    path::PathBuf,
    process::{self, Command},
};

const DRIVER_ENV: &str = "RULES_RS_DYLINT_DRIVER";
const LIBS_ENV: &str = "RULES_RS_DYLINT_LIBS";
const TOML_PATH_ENV: &str = "RULES_RS_DYLINT_TOML_PATH";
const RUSTC_LIB_DIRS_ENV: &str = "RULES_RS_DYLINT_RUSTC_LIB_DIRS";

fn main() {
    if let Err(error) = run() {
        eprintln!("rules_rs dylint runner: {error}");
        process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let driver = required_os_var(DRIVER_ENV)?;
    let libs = required_os_var(LIBS_ENV)?;

    let mut command = Command::new(driver);
    command.args(env::args_os().skip(1));
    command.env("DYLINT_LIBS", libs);

    let dylint_toml = if let Some(path) = env::var_os(TOML_PATH_ENV) {
        fs::read_to_string(&path).map_err(|error| {
            format!(
                "failed to read `{}`: {error}",
                PathBuf::from(path).display()
            )
        })?
    } else {
        // Dylint falls back to `cargo metadata` when `DYLINT_TOML` is absent.
        // Bazel actions should not consult ambient workspace state, so an omitted
        // config means "use an empty target-local config", not "discover one
        // globally".
        String::new()
    };
    command.env("DYLINT_TOML", dylint_toml);

    let rustc_lib_dirs = newline_separated_paths(RUSTC_LIB_DIRS_ENV);
    if !rustc_lib_dirs.is_empty() {
        expose_dynamic_libraries(&mut command, rustc_lib_dirs)?;
    }

    let status = command
        .status()
        .map_err(|error| format!("failed to start dylint driver: {error}"))?;

    process::exit(status.code().unwrap_or(1));
}

fn required_os_var(name: &str) -> Result<OsString, String> {
    env::var_os(name).ok_or_else(|| format!("missing required environment variable `{name}`"))
}

fn newline_separated_paths(name: &str) -> Vec<PathBuf> {
    env::var_os(name)
        .map(|value| {
            value
                .to_string_lossy()
                .lines()
                .filter(|line| !line.is_empty())
                .map(PathBuf::from)
                .collect()
        })
        .unwrap_or_default()
}

fn expose_dynamic_libraries(
    command: &mut Command,
    mut extra_dirs: Vec<PathBuf>,
) -> Result<(), String> {
    let loader_var = if cfg!(target_os = "windows") {
        "PATH"
    } else if cfg!(target_os = "macos") {
        "DYLD_LIBRARY_PATH"
    } else {
        "LD_LIBRARY_PATH"
    };

    if let Some(existing) = env::var_os(loader_var) {
        extra_dirs.extend(env::split_paths(&existing));
    }

    let joined = env::join_paths(extra_dirs)
        .map_err(|error| format!("failed to build `{loader_var}`: {error}"))?;
    command.env(loader_var, joined);
    Ok(())
}
