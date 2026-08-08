use std::env;
use std::process::Command;

fn run() -> Result<(), String> {
    let args = env::args().collect::<Vec<_>>();
    if args.len() < 3 {
        return Err("usage: expect_missed_mutants <cargo-mutants-test> <expected>".to_owned());
    }

    let output = Command::new(&args[1])
        .output()
        .map_err(|err| format!("failed to run {}: {err}", args[1]))?;
    let combined = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr),
    );
    if output.status.success() {
        return Err(format!(
            "mutation test passed, but surviving mutants were expected\n{combined}"
        ));
    }
    if !combined.contains(&args[2]) {
        return Err(format!(
            "mutation output did not contain expected text `{}`\n{combined}",
            args[2],
        ));
    }

    Ok(())
}

fn main() {
    if let Err(err) = run() {
        eprintln!("{err}");
        std::process::exit(1);
    }
}
