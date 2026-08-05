"""Providers for cargo-mutants rules."""

CargoMutantsInfo = provider(
    doc = "Everything needed to replay a Rust test binary build once per mutant.",
    fields = {
        "inputs": "depset[File]: Every file the recorded command line reads, keyed by exec path.",
        "manifest": "File: Multiline args file describing the replay to cargo_mutants_runner.",
        "mutants_json": "File: `cargo-mutants --list --json` output for the crate under test.",
    },
)
