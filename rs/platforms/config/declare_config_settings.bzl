"""Config settings for Rust target triples."""

load("//rs/platforms:triples.bzl", "ALL_TARGET_TRIPLES", "triple_to_constraint_set")

def declare_config_settings(targets = ALL_TARGET_TRIPLES):
    for target_triple in targets:
        native.config_setting(
            name = target_triple,
            constraint_values = triple_to_constraint_set(target_triple),
            visibility = ["//visibility:public"],
        )
