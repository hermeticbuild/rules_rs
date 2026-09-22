"""Select Cargo attributes by resolution and compilation platform."""

load("@rules_rust//rust/platform:triple_mappings.bzl", _legacy_constraints = "triple_to_constraint_set")
load("//rs/platforms:triples.bzl", "triple_to_rust_constraint_set")
load(":select_utils.bzl", "platform_label")

_SETTING = str(Label("@rules_rust//cargo/settings:cargo_execution_target"))

def cargo_condition(hub_name, context, triple):
    return "@" + hub_name + "//:__cargo/" + (context or "normal") + "/" + triple

def cargo_config_settings(contexts, triples, use_legacy_rules_rust_platforms = False):
    for context in contexts:
        for triple in triples:
            if use_legacy_rules_rust_platforms:
                constraints = _legacy_constraints(triple.replace("-musl", "-gnu").replace("-gnullvm", "-msvc"))
            else:
                constraints = triple_to_rust_constraint_set(triple)
            native.config_setting(
                name = "__cargo/" + (context or "normal") + "/" + triple,
                flag_values = {_SETTING: context},
                constraint_values = constraints,
                visibility = ["//visibility:public"],
            )

def cargo_select(values, hub_name, use_legacy_rules_rust_platforms = False, default = None):
    """Select values[context][triple], preserving legacy platform precedence."""
    branches = {}
    first = None
    same = True
    for context, by_triple in values.items():
        by_platform = {}
        for triple in sorted(by_triple):
            by_platform[platform_label(triple, use_legacy_rules_rust_platforms)] = triple
        for triple in by_platform.values():
            value = by_triple[triple]
            branches[cargo_condition(hub_name, context, triple)] = value
            if first == None:
                first = value
            elif first != value:
                same = False
    if not branches:
        return default
    if same and (default == None or first == default):
        return first
    if default != None:
        branches["//conditions:default"] = default
    return select(branches)
