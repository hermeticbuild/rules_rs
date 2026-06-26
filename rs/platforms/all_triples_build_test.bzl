"""Asserts every supported target triple resolves to a single config setting.

A probe carrying a `select()` over the per-triple `//rs/platforms/config`
settings -- the same keys the generated Rust toolchain selects its
`target_triple` on -- is transitioned onto every platform in
`ALL_TARGET_TRIPLES`. If two triples project to the same constraint set, that
select matches both under a platform and fails analysis with an ambiguous match,
so this fails if any pair collides. New triples are covered automatically.

The probe emits only a marker, so the test stays analysis-only and needs no
C/std toolchains for bare-metal targets.
"""

load("@bazel_skylib//rules:build_test.bzl", "build_test")
load(":triples.bzl", "ALL_TARGET_TRIPLES")

def _triple_select_probe_impl(ctx):
    marker = ctx.actions.declare_file(ctx.label.name + ".triple")
    ctx.actions.write(marker, ctx.attr.triple + "\n")
    return [DefaultInfo(files = depset([marker]))]

# Resolving `triple` exercises the same per-triple config_setting select the
# generated toolchain uses; an ambiguous match means two triples collided.
_triple_select_probe = rule(
    implementation = _triple_select_probe_impl,
    attrs = {"triple": attr.string(mandatory = True)},
)

def _all_platforms_transition_impl(_settings, _attr):
    return {
        target_triple: {
            "//command_line_option:platforms": [str(Label("//rs/platforms:" + target_triple))],
        }
        for target_triple in ALL_TARGET_TRIPLES
    }

_all_platforms_transition = transition(
    implementation = _all_platforms_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _resolve_all_triples_impl(ctx):
    marker = ctx.actions.declare_file(ctx.label.name + ".marker")
    ctx.actions.write(marker, "ok\n")
    return [DefaultInfo(files = depset([marker]))]

_resolve_all_triples = rule(
    implementation = _resolve_all_triples_impl,
    attrs = {
        "probes": attr.label(
            cfg = _all_platforms_transition,
            mandatory = True,
        ),
        "_allowlist_function_transition": attr.label(
            default = Label("@bazel_tools//tools/allowlists/function_transition_allowlist"),
        ),
    },
)

def all_triples_build_test(name = "all_triples_build_test"):
    _triple_select_probe(
        name = "triple_probe",
        triple = select({
            "//rs/platforms/config:" + target_triple: target_triple
            for target_triple in ALL_TARGET_TRIPLES
        }),
        tags = ["manual"],
    )

    _resolve_all_triples(
        name = "resolve_all_triples",
        probes = ":triple_probe",
        tags = ["manual"],
    )

    build_test(
        name = name,
        targets = [":resolve_all_triples"],
    )
