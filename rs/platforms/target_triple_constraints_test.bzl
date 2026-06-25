"""Analyzes a Rust library for every target triple with an additional constraint."""

load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("@rules_rust//rust:defs.bzl", "rust_library")
load(":triples.bzl", "ADDITIONAL_TARGET_TRIPLE_CONSTRAINTS")

_DEFAULT_ALLOCATOR_LIBRARY = "@rules_rust//rust/settings:default_allocator_library"

def _target_triples_transition_impl(_settings, _attr):
    return {
        target_triple: {
            _DEFAULT_ALLOCATOR_LIBRARY: "@rules_rust//rust/private/cc:empty",
            "//command_line_option:platforms": [str(Label("//rs/platforms:" + target_triple))],
        }
        for target_triple in ADDITIONAL_TARGET_TRIPLE_CONSTRAINTS
    }

_target_triples_transition = transition(
    implementation = _target_triples_transition_impl,
    inputs = [],
    outputs = [
        _DEFAULT_ALLOCATOR_LIBRARY,
        "//command_line_option:platforms",
    ],
)

def _analyze_target_triples_impl(ctx):
    marker = ctx.actions.declare_file(ctx.label.name + ".marker")
    ctx.actions.write(marker, "\n".join(sorted(ctx.split_attr.target.keys())))
    return [DefaultInfo(files = depset([marker]))]

_analyze_target_triples = rule(
    implementation = _analyze_target_triples_impl,
    attrs = {
        "target": attr.label(
            cfg = _target_triples_transition,
            mandatory = True,
        ),
        "_allowlist_function_transition": attr.label(
            default = Label("@bazel_tools//tools/allowlists/function_transition_allowlist"),
        ),
    },
)

def target_triple_constraints_test(name = "target_triple_constraints_test"):
    rust_library(
        name = "target_triple_constraints_rust_library",
        srcs = ["target_triple_constraints_test.rs"],
        crate_name = "target_triple_constraints_test",
        tags = ["manual"],
    )

    _analyze_target_triples(
        name = "analyze_target_triples_with_additional_constraints",
        target = ":target_triple_constraints_rust_library",
        tags = ["manual"],
    )

    build_test(
        name = name,
        targets = [":analyze_target_triples_with_additional_constraints"],
    )
