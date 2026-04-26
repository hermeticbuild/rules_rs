use std::env;
use std::ffi::OsString;
use std::fs;
use std::path::PathBuf;
use std::process::{self, Command};

fn load_args_file() -> Result<Vec<OsString>, String> {
    let args = env::args_os().skip(1).collect::<Vec<_>>();
    if args.len() != 1 {
        return Err("usage: miri_test_runner @args-file".to_owned());
    }

    let arg = args[0].to_string_lossy();
    let Some(args_file) = arg.strip_prefix('@') else {
        return Err(format!("expected @args-file, got {}", args[0].to_string_lossy()));
    };
    if args_file.is_empty() {
        return Err("missing args file after @".to_owned());
    }

    let args_file = PathBuf::from(args_file);
    let content = fs::read_to_string(&args_file)
        .map_err(|err| format!("failed to read {}: {err}", args_file.display()))?;
    Ok(content.lines().map(OsString::from).collect())
}

fn run() -> Result<i32, String> {
    let mut args = load_args_file()?.into_iter();
    let miri = args
        .next()
        .ok_or_else(|| "missing miri path in args file".to_owned())?;

    let mut command = Command::new(miri);
    command.args(args);

    let status = command
        .status()
        .map_err(|err| format!("failed to run Miri: {err}"))?;
    Ok(status.code().unwrap_or(1))
}

fn main() {
    match run() {
        Ok(code) => process::exit(code),
        Err(err) => {
            eprintln!("{err}");
            process::exit(1);
        }
    }
}
