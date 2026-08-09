"""Mutation testing for Rust crates."""

load("@hermetic_launcher//launcher:lib.bzl", "launcher")
load("//rs/experimental/mutants/private:aspect.bzl", _cargo_mutants_aspect = "cargo_mutants_aspect")
load("//rs/experimental/mutants/private:providers.bzl", "CargoMutantsInfo")

cargo_mutants_aspect = _cargo_mutants_aspect

def _declare_test_executable(ctx):
    name = ctx.label.name
    if ctx.target_platform_has_constraint(ctx.attr._windows_constraint[platform_common.ConstraintValueInfo]):
        name += ".exe"
    return ctx.actions.declare_file(name)

def _cargo_mutants_test_impl(ctx):
    info = ctx.attr.test[CargoMutantsInfo]

    embedded_args, transformed_args = launcher.args_from_entrypoint(ctx.executable._runner)
    embedded_args.extend([
        "@" + info.manifest.path,
        "--timeout-multiplier",
        str(ctx.attr.timeout_multiplier),
        "--jobs",
        str(ctx.attr.jobs),
    ])

    executable = _declare_test_executable(ctx)
    launcher.compile_stub(
        ctx = ctx,
        embedded_args = embedded_args,
        transformed_args = transformed_args,
        output_file = executable,
    )

    # The recorded command line is exec-root relative, so mirror exec paths into
    # the runfiles root; the runner chdirs there and replays it with no rewriting.
    runfiles = ctx.runfiles(
        files = [ctx.executable._runner] + ctx.files.data,
        root_symlinks = {file.path: file for file in info.inputs.to_list()},
    ).merge_all(
        [ctx.attr.test[DefaultInfo].default_runfiles, ctx.attr._runner[DefaultInfo].default_runfiles] +
        [data[DefaultInfo].default_runfiles for data in ctx.attr.data],
    )

    environment = dict(ctx.attr.test[RunEnvironmentInfo].environment)
    environment.update(ctx.attr.env)

    return [
        DefaultInfo(executable = executable, runfiles = runfiles),
        RunEnvironmentInfo(
            environment = environment,
            inherited_environment = ctx.attr.test[RunEnvironmentInfo].inherited_environment,
        ),
    ]

cargo_mutants_test = rule(
    implementation = _cargo_mutants_test_impl,
    doc = """Rebuilds and re-runs a `rust_test` target once per mutant.

Mutants are enumerated by `cargo-mutants`, which you supply yourself:

```python
# MODULE.bazel
crate.annotation(crate = "cargo-mutants", gen_binaries = ["cargo-mutants"])
```

```
# .bazelrc
build --@rules_rs//rs/experimental/mutants:cargo_mutants_binary=@crates//:cargo-mutants__cargo-mutants
```

Only the test target's own `#[cfg(test)]` tests run against each mutant;
separate integration-test crates are not rebuilt.

Sweeps are slow — every mutant is a fresh link plus a test run. Use `jobs` to
fan out within one machine and the standard `shard_count` attribute to fan out
across several.
""",
    attrs = {
        "data": attr.label_list(allow_files = True),
        "env": attr.string_dict(doc = "Environment variables set while running the mutation sweep."),
        "jobs": attr.int(
            default = 1,
            doc = """Mutants to build and test concurrently within one shard.

Each job gets its own scratch build tree, so raising this costs disk and
memory as well as CPU. To spread the work over several machines instead, set
`shard_count`.""",
        ),
        "test": attr.label(
            mandatory = True,
            aspects = [_cargo_mutants_aspect],
            providers = [CargoMutantsInfo],
            doc = "The `rust_test` target to mutate.",
        ),
        "timeout_multiplier": attr.int(
            default = 5,
            doc = "Mutant test timeout, as a multiple of the unmutated run's duration.",
        ),
        "_runner": attr.label(
            default = Label("//rs/experimental/mutants/private:cargo_mutants_runner"),
            executable = True,
            cfg = "target",
        ),
        "_windows_constraint": attr.label(default = "@platforms//os:windows"),
    },
    test = True,
    toolchains = [
        launcher.finalizer_toolchain_type,
        launcher.template_toolchain_type,
    ],
)
