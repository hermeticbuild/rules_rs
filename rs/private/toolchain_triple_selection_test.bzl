load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//rs/platforms:triples.bzl", "ALL_TARGET_TRIPLES", "SUPPORTED_EXEC_TRIPLES")
load(
    ":toolchain_triple_selection.bzl",
    "add_version_triples",
    "downloadable_stdlib_targets",
    "resolve_toolchain_execs",
    "resolve_toolchain_targets",
)

def _empty_selections_use_defaults_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(env, SUPPORTED_EXEC_TRIPLES, resolve_toolchain_execs([]))
    asserts.equals(env, ALL_TARGET_TRIPLES, resolve_toolchain_targets([]))

    return unittest.end(env)

def _custom_selections_are_deduplicated_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        ["aarch64-unknown-linux-gnu", "x86_64-unknown-linux-gnu"],
        resolve_toolchain_execs([
            "aarch64-unknown-linux-gnu",
            "x86_64-unknown-linux-gnu",
            "aarch64-unknown-linux-gnu",
        ]),
    )
    asserts.equals(
        env,
        ["aarch64-unknown-linux-gnu"],
        resolve_toolchain_targets([
            "aarch64-unknown-linux-gnu",
            "aarch64-unknown-linux-gnu",
        ]),
    )

    return unittest.end(env)

def _version_selections_are_merged_impl(ctx):
    env = unittest.begin(ctx)
    selections = {}

    add_version_triples(selections, "1.78.0", ["x86_64-unknown-linux-gnu"])
    add_version_triples(
        selections,
        "1.78.0",
        ["aarch64-unknown-linux-gnu", "x86_64-unknown-linux-gnu"],
    )
    add_version_triples(selections, "nightly", ["aarch64-apple-darwin"])

    asserts.equals(env, {
        "1.78.0": [
            "x86_64-unknown-linux-gnu",
            "aarch64-unknown-linux-gnu",
        ],
        "nightly": ["aarch64-apple-darwin"],
    }, selections)

    return unittest.end(env)

def _only_distributed_stdlibs_are_downloaded_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        ["aarch64-unknown-linux-gnu"],
        downloadable_stdlib_targets([
            "bpfel-unknown-none",
            "aarch64-unknown-linux-gnu",
        ]),
    )

    return unittest.end(env)

empty_selections_use_defaults_test = unittest.make(_empty_selections_use_defaults_impl)
custom_selections_are_deduplicated_test = unittest.make(_custom_selections_are_deduplicated_impl)
version_selections_are_merged_test = unittest.make(_version_selections_are_merged_impl)
only_distributed_stdlibs_are_downloaded_test = unittest.make(_only_distributed_stdlibs_are_downloaded_impl)

def toolchain_triple_selection_tests():
    return unittest.suite(
        "toolchain_triple_selection_tests",
        empty_selections_use_defaults_test,
        custom_selections_are_deduplicated_test,
        version_selections_are_merged_test,
        only_distributed_stdlibs_are_downloaded_test,
    )
