//! Rebuilds and re-runs a Rust test binary once per mutant.
//!
//! The aspect records the exact `rustc --test` command line rules_rust would
//! run, in exec-root-relative form, and mirrors every input into the runfiles
//! root under its exec path. So the loop here is: chdir to the runfiles root,
//! swap the crate root and output path for copies under `$TEST_TMPDIR`, and
//! replay. A mutant that makes the tests fail (or hang) is killed; one that
//! leaves them passing is MISSED and fails the test.

use std::collections::BTreeMap;
use std::env;
use std::ffi::OsString;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

const POLL: Duration = Duration::from_millis(50);
const MIN_TIMEOUT: Duration = Duration::from_secs(20);
const BASELINE_TIMEOUT: Duration = Duration::from_secs(900);

/// Replaces the region between `start` and `end` (1-based line/char column,
/// end exclusive) with `replacement`.
///
/// Ported from cargo-mutants' `Span::replace` so the offsets in `mutants.json`
/// mean here exactly what they mean there.
fn span_replace(
    source: &str,
    start: (usize, usize),
    end: (usize, usize),
    replacement: &str,
) -> String {
    let mut out = String::with_capacity(source.len() + replacement.len());
    let (mut line, mut column) = (1usize, 1usize);
    for c in source.chars() {
        if (line, column) == start {
            out.push_str(replacement);
        }
        if line < start.0
            || line > end.0
            || (line == start.0 && column < start.1)
            || (line == end.0 && column >= end.1)
        {
            out.push(c);
        }
        if c == '\n' {
            line += 1;
            column = 1;
        } else if c != '\r' {
            // A carriage return counts as part of the last column.
            column += 1;
        }
    }
    if (line, column) == start {
        out.push_str(replacement);
    }
    out
}

struct Manifest {
    process_wrapper: PathBuf,
    mutants: PathBuf,
    rustc_args: Vec<PathBuf>,
    env: PathBuf,
    crate_root: String,
    output: String,
    srcs: Vec<PathBuf>,
    compile_data: Vec<PathBuf>,
    test_args: Vec<String>,
    timeout_multiplier: u32,
    jobs: usize,
}

fn parse_manifest() -> Result<Manifest, String> {
    let mut argv: Vec<String> = Vec::new();
    for arg in env::args().skip(1) {
        match arg.strip_prefix('@') {
            Some(path) => {
                let text = fs::read_to_string(path)
                    .map_err(|err| format!("failed to read manifest {path}: {err}"))?;
                argv.extend(text.lines().map(str::to_owned));
            }
            None => argv.push(arg),
        }
    }

    let mut process_wrapper = None;
    let mut mutants = None;
    let mut rustc_args = Vec::new();
    let mut env_file = None;
    let mut crate_root = None;
    let mut output = None;
    let mut srcs = Vec::new();
    let mut compile_data = Vec::new();
    let mut test_args = Vec::new();
    let mut timeout_multiplier = 5;
    let mut jobs = 1;

    let mut argv = argv.into_iter();
    while let Some(flag) = argv.next() {
        let value = argv
            .next()
            .ok_or_else(|| format!("missing value for {flag}"))?;
        match flag.as_str() {
            "--process-wrapper" => process_wrapper = Some(PathBuf::from(value)),
            "--mutants" => mutants = Some(PathBuf::from(value)),
            "--rustc-args" => rustc_args.push(PathBuf::from(value)),
            "--env" => env_file = Some(PathBuf::from(value)),
            "--crate-root" => crate_root = Some(value),
            "--output" => output = Some(value),
            "--src" => srcs.push(PathBuf::from(value)),
            "--compile-data" => compile_data.push(PathBuf::from(value)),
            "--test-arg" => test_args.push(value),
            "--timeout-multiplier" => {
                timeout_multiplier = value
                    .parse()
                    .map_err(|err| format!("bad --timeout-multiplier {value}: {err}"))?
            }
            "--jobs" => {
                jobs = value
                    .parse()
                    .map_err(|err| format!("bad --jobs {value}: {err}"))?
            }
            other => return Err(format!("unknown flag {other}")),
        }
    }

    Ok(Manifest {
        process_wrapper: process_wrapper.ok_or("missing --process-wrapper")?,
        mutants: mutants.ok_or("missing --mutants")?,
        rustc_args,
        env: env_file.ok_or("missing --env")?,
        crate_root: crate_root.ok_or("missing --crate-root")?,
        output: output.ok_or("missing --output")?,
        srcs,
        compile_data,
        test_args,
        timeout_multiplier: timeout_multiplier.max(1),
        jobs: jobs.max(1),
    })
}

/// Bazel's native test sharding, as `(index, total)`.
///
/// Creating the status file is how a test runner tells Bazel it honoured the
/// split; without it Bazel fails the target rather than silently running the
/// whole set in every shard.
fn shard() -> Result<(usize, usize), String> {
    let total = match env::var("TEST_TOTAL_SHARDS") {
        Ok(total) => total
            .parse::<usize>()
            .map_err(|err| format!("bad TEST_TOTAL_SHARDS {total:?}: {err}"))?,
        Err(_) => return Ok((0, 1)),
    };
    if total == 0 {
        return Ok((0, 1));
    }
    let index = env::var("TEST_SHARD_INDEX")
        .map_err(|_| "TEST_TOTAL_SHARDS is set but TEST_SHARD_INDEX is not".to_owned())?;
    let index = index
        .parse::<usize>()
        .map_err(|err| format!("bad TEST_SHARD_INDEX {index:?}: {err}"))?;
    if index >= total {
        return Err(format!(
            "TEST_SHARD_INDEX {index} is out of range for {total} shards"
        ));
    }
    if let Some(status) = env::var_os("TEST_SHARD_STATUS_FILE") {
        write(Path::new(&status), "")?;
    }
    Ok((index, total))
}

fn read_lines(path: &Path) -> Result<Vec<String>, String> {
    Ok(fs::read_to_string(path)
        .map_err(|err| format!("failed to read {}: {err}", path.display()))?
        .lines()
        .map(str::to_owned)
        .collect())
}

/// cargo-mutants normalizes line endings before computing spans, so we must too.
fn read_source(path: &Path) -> Result<String, String> {
    Ok(fs::read_to_string(path)
        .map_err(|err| format!("failed to read {}: {err}", path.display()))?
        .replace("\r\n", "\n"))
}

fn write(path: &Path, contents: &str) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|err| format!("failed to create {}: {err}", parent.display()))?;
    }
    fs::write(path, contents).map_err(|err| format!("failed to write {}: {err}", path.display()))
}

fn copy(path: &Path, dest: &Path) -> Result<(), String> {
    if let Some(parent) = dest.parent() {
        fs::create_dir_all(parent)
            .map_err(|err| format!("failed to create {}: {err}", parent.display()))?;
    }
    fs::copy(path, dest).map(|_| ()).map_err(|err| {
        format!(
            "failed to copy {} to {}: {err}",
            path.display(),
            dest.display()
        )
    })
}

fn wait_with_timeout(mut child: Child, timeout: Duration) -> Result<Option<i32>, String> {
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return Ok(Some(status.code().unwrap_or(1))),
            Ok(None) => {}
            Err(err) => return Err(format!("failed to wait for child: {err}")),
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            return Ok(None);
        }
        std::thread::sleep(POLL);
    }
}

struct Replay {
    process_wrapper: PathBuf,
    argv: Vec<String>,
    env: Vec<(String, String)>,
    binary: PathBuf,
    test_args: Vec<String>,
    test_working_dir: PathBuf,
}

impl Replay {
    /// Compiles the current contents of the scratch tree. A failure is not an
    /// error: a mutant that does not compile is what cargo-mutants calls
    /// "unviable". `Err` is reserved for not being able to run rustc at all.
    fn build(&self) -> Result<Result<(), String>, String> {
        let out = Command::new(&self.process_wrapper)
            .args(&self.argv)
            .env_clear()
            .envs(self.env.iter().map(|(key, value)| (key, value)))
            .output()
            .map_err(|err| format!("failed to run {}: {err}", self.process_wrapper.display()))?;
        Ok(if out.status.success() {
            Ok(())
        } else {
            Err(String::from_utf8_lossy(&out.stderr).into_owned())
        })
    }

    fn run_tests(&self, timeout: Duration) -> Result<Option<i32>, String> {
        let child = Command::new(&self.binary)
            .args(&self.test_args)
            .current_dir(&self.test_working_dir)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|err| format!("failed to run {}: {err}", self.binary.display()))?;
        wait_with_timeout(child, timeout)
    }
}

fn substitute(value: &str, from: &str, to: &Path) -> String {
    value.replace(from, &to.to_string_lossy())
}

fn link(target: &Path, dest: &Path) -> Result<(), String> {
    #[cfg(unix)]
    let result = std::os::unix::fs::symlink(target, dest);
    #[cfg(windows)]
    let result = fs::copy(target, dest).map(|_| ());
    result.map_err(|err| format!("failed to link {}: {err}", dest.display()))
}

/// Returns the directory to replay from — one whose layout mirrors exec paths.
///
/// Normally that is the runfiles tree, but `--nobuild_runfile_links` leaves it
/// unmaterialized, so rebuild it from the manifest. Links suffice: every write
/// the replay makes is redirected into `scratch`.
fn replay_root(scratch: &Path) -> Result<PathBuf, String> {
    let srcdir = env::var_os("TEST_SRCDIR")
        .map(PathBuf::from)
        .ok_or("TEST_SRCDIR is not set; cargo_mutants_test must be run as a test")?;
    if srcdir.is_dir() {
        return Ok(srcdir);
    }

    let manifest = env::var_os("RUNFILES_MANIFEST_FILE")
        .map(PathBuf::from)
        .ok_or("neither a runfiles tree nor RUNFILES_MANIFEST_FILE is available")?;
    let root = scratch.join("runfiles");
    for entry in read_lines(&manifest)? {
        let (rel, target) = entry.split_once(' ').unwrap_or((entry.as_str(), ""));
        let dest = root.join(rel);
        if let Some(parent) = dest.parent() {
            fs::create_dir_all(parent)
                .map_err(|err| format!("failed to create {}: {err}", parent.display()))?;
        }
        if target.is_empty() {
            fs::write(&dest, "")
                .map_err(|err| format!("failed to write {}: {err}", dest.display()))?;
        } else {
            link(Path::new(target), &dest)?;
        }
    }
    Ok(root)
}

enum Outcome {
    Caught,
    Unviable,
    Missed(String),
}

/// Prepares one replay sandbox: a private copy of the sources, plus a command
/// line whose reads and writes are redirected into it.
///
/// Concurrent jobs cannot share one — they patch the same files and link to the
/// same output path.
fn prepare(
    scratch: &Path,
    manifest: &Manifest,
    args: &[String],
    environment: &[(String, String)],
    originals: &BTreeMap<PathBuf, String>,
    test_working_dir: &Path,
) -> Result<Replay, String> {
    for (src, text) in originals {
        write(&scratch.join(src), text)?;
    }
    for data in &manifest.compile_data {
        if !originals.contains_key(data) {
            copy(data, &scratch.join(data))?;
        }
    }
    let crate_root = scratch.join(&manifest.crate_root);
    let binary = scratch.join("mutant_test_binary");
    let mut argv = Vec::with_capacity(args.len());
    for arg in args {
        // rustc drops its intermediate `.rcgu.o` files in `--out-dir` and
        // deletes them after linking, so jobs sharing one clobber each other.
        if let Some(dir) = arg.strip_prefix("--out-dir=") {
            let dir = scratch.join(dir);
            fs::create_dir_all(&dir)
                .map_err(|err| format!("failed to create {}: {err}", dir.display()))?;
            argv.push(format!("--out-dir={}", dir.display()));
            continue;
        }
        let arg = substitute(arg, &manifest.output, &binary);
        argv.push(substitute(&arg, &manifest.crate_root, &crate_root));
    }
    Ok(Replay {
        process_wrapper: manifest.process_wrapper.clone(),
        argv,
        env: environment.to_vec(),
        binary,
        test_args: manifest.test_args.clone(),
        test_working_dir: test_working_dir.to_path_buf(),
    })
}

fn evaluate(
    replay: &Replay,
    scratch: &Path,
    originals: &BTreeMap<PathBuf, String>,
    mutant: &serde_json::Value,
    timeout: Duration,
) -> Result<Outcome, String> {
    // `mutants_list` copies sources to `<tree>/src/<exec path>`.
    let file = mutant["file"]
        .as_str()
        .and_then(|f| f.strip_prefix("src/"))
        .ok_or_else(|| format!("mutant has no `src/`-relative file field: {mutant}"))?;
    let replacement = mutant["replacement"]
        .as_str()
        .ok_or_else(|| format!("mutant has no replacement: {mutant}"))?;
    let at = |end: &str, part: &str| -> Result<usize, String> {
        mutant["span"][end][part]
            .as_u64()
            .map(|n| n as usize)
            .ok_or_else(|| format!("mutant has no span.{end}.{part}: {mutant}"))
    };
    let start = (at("start", "line")?, at("start", "column")?);
    let end = (at("end", "line")?, at("end", "column")?);

    let source = originals
        .get(Path::new(file))
        .ok_or_else(|| format!("mutant names {file}, which is not a source of this crate"))?;
    let path = scratch.join(file);
    write(&path, &span_replace(source, start, end, replacement))?;
    let built = replay.build()?;
    write(&path, source)?;

    if built.is_err() {
        return Ok(Outcome::Unviable);
    }
    if replay.run_tests(timeout)? == Some(0) {
        Ok(Outcome::Missed(format!(
            "{file}:{}:{}: replace {} with {replacement}",
            start.0,
            start.1,
            mutant["function"]["function_name"].as_str().unwrap_or("?"),
        )))
    } else {
        Ok(Outcome::Caught)
    }
}

fn run() -> Result<(), String> {
    let (shard_index, shard_total) = shard()?;
    let scratch = PathBuf::from(
        env::var_os("TEST_TMPDIR").unwrap_or_else(|| OsString::from(env::temp_dir())),
    )
    .join("cargo_mutants");
    let _ = fs::remove_dir_all(&scratch);

    // Everything below is exec-root relative; the replay root mirrors it.
    let runfiles = replay_root(&scratch)?;
    env::set_current_dir(&runfiles)
        .map_err(|err| format!("failed to enter {}: {err}", runfiles.display()))?;
    let test_working_dir = env::var_os("TEST_WORKSPACE")
        .map(|workspace| runfiles.join(workspace))
        .unwrap_or_else(|| runfiles.clone());

    // Parsed only now: the `@manifest` argument is itself an exec-root path.
    let manifest = parse_manifest()?;

    let mut originals: BTreeMap<PathBuf, String> = BTreeMap::new();
    for src in &manifest.srcs {
        originals.insert(src.clone(), read_source(src)?);
    }

    let mut args = Vec::new();
    for args_file in &manifest.rustc_args {
        args.extend(read_lines(args_file)?);
    }

    // rules_rust relies on process_wrapper to expand these; it only sees the
    // ones on the command line, so expand the recorded environment here.
    let cwd = runfiles.to_string_lossy().into_owned();
    let mut environment: Vec<(String, String)> = Vec::new();
    for line in read_lines(&manifest.env)? {
        let (key, value) = line
            .split_once('=')
            .ok_or_else(|| format!("malformed env entry {line:?}"))?;
        let value = value
            .replace("${pwd}", &cwd)
            .replace("${exec_root}", &cwd)
            .replace("${output_base}", &cwd);
        environment.push((key.to_owned(), value));
    }
    for key in ["PATH", "HOME", "SYSTEMROOT", "TMPDIR", "TEST_TMPDIR"] {
        if let Some(value) = env::var_os(key) {
            environment.push((key.to_owned(), value.to_string_lossy().into_owned()));
        }
    }

    let mutants: serde_json::Value = serde_json::from_str(&read_source(&manifest.mutants)?)
        .map_err(|err| format!("failed to parse {}: {err}", manifest.mutants.display()))?;
    let mutants = mutants
        .as_array()
        .ok_or("expected `cargo-mutants --list --json` to emit an array")?;
    let work: Vec<&serde_json::Value> = mutants
        .iter()
        .skip(shard_index)
        .step_by(shard_total)
        .collect();

    let jobs = manifest.jobs.min(work.len().max(1));
    let scratches: Vec<PathBuf> = (0..jobs).map(|job| scratch.join(job.to_string())).collect();
    let replays = scratches
        .iter()
        .map(|scratch| {
            prepare(
                scratch,
                &manifest,
                &args,
                &environment,
                &originals,
                &test_working_dir,
            )
        })
        .collect::<Result<Vec<_>, _>>()?;

    if let Err(stderr) = replays[0].build()? {
        return Err(format!("the unmutated crate failed to build:\n{stderr}"));
    }
    let started = Instant::now();
    match replays[0].run_tests(BASELINE_TIMEOUT)? {
        Some(0) => {}
        _ => return Err("the unmutated tests do not pass; fix them first".to_owned()),
    }
    let timeout = (started.elapsed() * manifest.timeout_multiplier).max(MIN_TIMEOUT);

    let next = AtomicUsize::new(0);
    let outcomes: Mutex<Vec<Outcome>> = Mutex::new(Vec::new());
    let failure: Mutex<Option<String>> = Mutex::new(None);
    std::thread::scope(|scope| {
        for (replay, scratch) in replays.iter().zip(&scratches) {
            let (next, outcomes, failure) = (&next, &outcomes, &failure);
            let (work, originals) = (&work, &originals);
            scope.spawn(move || {
                while failure.lock().unwrap().is_none() {
                    let Some(mutant) = work.get(next.fetch_add(1, Ordering::Relaxed)) else {
                        break;
                    };
                    match evaluate(replay, scratch, originals, mutant, timeout) {
                        Ok(outcome) => outcomes.lock().unwrap().push(outcome),
                        Err(err) => *failure.lock().unwrap() = Some(err),
                    }
                }
            });
        }
    });
    if let Some(err) = failure.into_inner().unwrap() {
        return Err(err);
    }

    let (mut caught, mut unviable) = (0usize, 0usize);
    let mut missed: Vec<String> = Vec::new();
    for outcome in outcomes.into_inner().unwrap() {
        match outcome {
            Outcome::Caught => caught += 1,
            Outcome::Unviable => unviable += 1,
            // Jobs finish out of order; sorted below so the log is stable.
            Outcome::Missed(label) => missed.push(label),
        }
    }
    missed.sort();

    println!(
        "{} mutants: {caught} caught, {} missed, {unviable} unviable",
        work.len(),
        missed.len()
    );
    for label in &missed {
        println!("MISSED {label}");
    }
    if missed.is_empty() {
        Ok(())
    } else {
        Err(format!("{} mutants survived", missed.len()))
    }
}

fn main() {
    if let Err(err) = run() {
        eprintln!("cargo_mutants: {err}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::span_replace;

    #[test]
    fn replaces_within_a_line() {
        assert_eq!(
            span_replace("fn a() -> i32 { 1 }", (1, 15), (1, 20), "{ 0 }"),
            "fn a() -> i32 { 0 }"
        );
    }

    #[test]
    fn replaces_across_lines() {
        let source = "fn a() {\n    body();\n}\n";
        assert_eq!(span_replace(source, (1, 8), (3, 2), "{}"), "fn a() {}\n");
    }

    #[test]
    fn replaces_at_end_of_input() {
        assert_eq!(span_replace("ab", (1, 3), (1, 3), "c"), "abc");
    }

    #[test]
    fn copies_compile_data_as_bytes() {
        let root =
            std::env::temp_dir().join(format!("cargo_mutants_runner_test.{}", std::process::id()));
        let source = root.join("source");
        let dest = root.join("dest");
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(&source, [0xff, 0x00, b'\n']).unwrap();
        super::copy(&source, &dest).unwrap();
        assert_eq!(std::fs::read(&dest).unwrap(), [0xff, 0x00, b'\n']);
        std::fs::remove_dir_all(root).unwrap();
    }
}
