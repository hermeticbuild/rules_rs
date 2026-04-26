use std::env;
use std::process::Command;

fn run() -> Result<(), String> {
    let args = env::args().collect::<Vec<_>>();
    if args.len() < 3 {
        return Err("usage: expect_miri_failure <miri-test> <expected>".to_owned());
    }

    let output = Command::new(&args[1])
        .output()
        .map_err(|err| format!("failed to run {}: {err}", args[1]))?;
    if output.status.success() {
        return Err("Miri test passed, but failure was expected".to_owned());
    }

    let combined = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr),
    );
    if !combined.contains(&args[2]) {
        return Err(format!(
            "Miri failure output did not contain expected text `{}`\n{combined}",
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
