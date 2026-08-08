//! Default value of `//rs/experimental/mutants:cargo_mutants_binary`.
//!
//! rules_rs does not vendor cargo-mutants (its releases are x86_64-only), so
//! the flag has to point at a binary the user builds from their own lockfile.

fn main() {
    eprintln!(
        "cargo-mutants is not configured. Add it to your Cargo.toml, then:\n\
         \n\
         # MODULE.bazel\n\
         crate.annotation(crate = \"cargo-mutants\", gen_binaries = [\"cargo-mutants\"])\n\
         \n\
         # .bazelrc\n\
         build --@rules_rs//rs/experimental/mutants:cargo_mutants_binary=@crates//:cargo-mutants__cargo-mutants"
    );
    std::process::exit(1);
}
