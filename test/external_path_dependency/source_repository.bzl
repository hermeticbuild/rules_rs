"""Materialize a tiny external Cargo source tree without network downloads."""

def _source_repository_impl(ctx):
    for path in [
        "Cargo.toml",
        "Cargo.lock",
        "src/lib.rs",
        "vendor/dependency/Cargo.toml",
        "vendor/dependency/src/lib.rs",
    ]:
        ctx.template(path, Label("//external_path_dependency:fixture/" + path), executable = False)
    ctx.file("BUILD.bazel", "exports_files([\"Cargo.toml\", \"Cargo.lock\"])\n")

    return ctx.repo_metadata(reproducible = True)

source_repository = repository_rule(implementation = _source_repository_impl)
