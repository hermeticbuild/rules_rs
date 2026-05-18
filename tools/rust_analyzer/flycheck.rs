//! Reads every `rust_analyzer_check_command` file the rules_rust analyzer
//! aspect produced for the saved file's Bazel package, then exec's each one to
//! typecheck the corresponding crate via rustc directly. No bazel hop per save.

use std::collections::BTreeMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Stdio};

use clap::Parser;
use serde::Deserialize;

const WORKSPACE_MARKERS: &[&str] = &["MODULE.bazel", "REPO.bazel", "WORKSPACE.bazel", "WORKSPACE"];
const BUILD_FILES: &[&str] = &["BUILD.bazel", "BUILD"];
const CHECK_COMMAND_SUFFIX: &str = ".rust_analyzer_check_command.json";

#[derive(Parser)]
#[command(version)]
struct CommandLine {
    /// Absolute path of the file that was just saved.
    saved_file: PathBuf,
}

#[derive(Debug, Deserialize)]
struct CheckCommand {
    argv: Vec<String>,
    env: BTreeMap<String, String>,
}

fn main() -> ExitCode {
    let command_line = CommandLine::parse();
    let Ok(saved_file) = command_line.saved_file.canonicalize() else {
        return ExitCode::SUCCESS;
    };
    let Some(workspace_root) = find_workspace_root(&saved_file) else {
        return ExitCode::SUCCESS;
    };
    let Ok(file_relative) = saved_file.strip_prefix(&workspace_root) else {
        return ExitCode::SUCCESS;
    };
    let Some(package_dir) = find_package_dir(&workspace_root, file_relative) else {
        return ExitCode::SUCCESS;
    };
    let Some(execroot) = resolve_execroot(&workspace_root) else {
        return ExitCode::SUCCESS;
    };

    let bin_dir = workspace_root.join("bazel-bin").join(&package_dir);
    for check_command_file in collect_check_command_files(&bin_dir) {
        run_check_command(&execroot, &check_command_file);
    }
    ExitCode::SUCCESS
}

fn find_workspace_root(saved_file: &Path) -> Option<PathBuf> {
    let mut dir = saved_file.parent()?;
    loop {
        if WORKSPACE_MARKERS
            .iter()
            .any(|marker| dir.join(marker).is_file())
        {
            return Some(dir.to_path_buf());
        }
        dir = dir.parent()?;
    }
}

fn find_package_dir(workspace_root: &Path, file_relative: &Path) -> Option<PathBuf> {
    let mut dir = file_relative.parent()?.to_path_buf();
    loop {
        let absolute = workspace_root.join(&dir);
        if BUILD_FILES
            .iter()
            .any(|name| absolute.join(name).is_file())
        {
            return Some(dir);
        }
        if !dir.pop() {
            return None;
        }
    }
}

/// rustc resolves transitive crate lookups relative to its cwd; running from
/// the repo root (where `bazel-out` is a symlink) breaks lookups for some
/// crates. Bazel runs the same actions from `execroot`, which is the parent of
/// the real `bazel-out` directory.
fn resolve_execroot(workspace_root: &Path) -> Option<PathBuf> {
    let bazel_out = workspace_root.join("bazel-out").canonicalize().ok()?;
    bazel_out.parent().map(Path::to_path_buf)
}

fn collect_check_command_files(bin_dir: &Path) -> Vec<PathBuf> {
    let Ok(entries) = fs::read_dir(bin_dir) else {
        return Vec::new();
    };
    entries
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|name| name.ends_with(CHECK_COMMAND_SUFFIX))
        })
        .collect()
}

fn run_check_command(execroot: &Path, path: &Path) {
    let Ok(contents) = fs::read_to_string(path) else {
        return;
    };
    let Ok(command) = serde_json::from_str::<CheckCommand>(&contents) else {
        return;
    };
    let Some((program, args)) = command.argv.split_first() else {
        return;
    };
    // rustc writes JSON diagnostics to stderr; rust-analyzer reads them from
    // our stdout. Hand the child a clone of our stdout fd to use as its
    // stderr, so its diagnostics land where the editor is listening.
    let stderr_for_child = clone_stdout_as_stderr_target().unwrap_or_else(Stdio::inherit);
    let _ = Command::new(program)
        .args(args)
        .envs(&command.env)
        .current_dir(execroot)
        .stderr(stderr_for_child)
        .status();
}

#[cfg(unix)]
fn clone_stdout_as_stderr_target() -> Option<Stdio> {
    use std::os::fd::AsFd;
    io::stdout().as_fd().try_clone_to_owned().ok().map(Stdio::from)
}

#[cfg(not(unix))]
fn clone_stdout_as_stderr_target() -> Option<Stdio> {
    None
}
