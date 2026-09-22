"""Select Cargo attributes by resolution and compilation platform."""

load("@rules_rust//rust/platform:triple_mappings.bzl", _legacy_constraints = "triple_to_constraint_set")
load("//rs/platforms:triples.bzl", "triple_to_rust_constraint_set")
load(":select_utils.bzl", "platform_label")

_SETTING = str(Label("@rules_rust//cargo/settings:cargo_target_triple"))

def cargo_condition(hub_name, cargo_target_triple, platform_triple):
    return "@" + hub_name + "//:__cargo/" + (cargo_target_triple or "default") + "/" + platform_triple

def cargo_config_settings(cargo_target_triples, platform_triples, use_legacy_rules_rust_platforms = False):
    for platform_triple in platform_triples:
        if use_legacy_rules_rust_platforms:
            constraints = _legacy_constraints(platform_triple.replace("-musl", "-gnu").replace("-gnullvm", "-msvc"))
        else:
            constraints = triple_to_rust_constraint_set(platform_triple)
        for cargo_target_triple in cargo_target_triples:
            native.config_setting(
                name = "__cargo/" + (cargo_target_triple or "default") + "/" + platform_triple,
                flag_values = {_SETTING: cargo_target_triple},
                constraint_values = constraints,
                visibility = ["//visibility:public"],
            )

def cargo_select(values, hub_name, use_legacy_rules_rust_platforms = False, default = None):
    """Select values[cargo_target_triple][platform_triple], preserving legacy platform precedence."""
    branches = {}
    first = None
    same = True
    for cargo_target_triple, by_triple in values.items():
        platform_triples = sorted(by_triple)
        if use_legacy_rules_rust_platforms:
            by_platform = {platform_label(platform_triple, True): platform_triple for platform_triple in platform_triples}
            platform_triples = by_platform.values()
        for platform_triple in platform_triples:
            value = by_triple[platform_triple]
            condition = cargo_condition(hub_name, cargo_target_triple, platform_triple) if hub_name else platform_label(platform_triple, use_legacy_rules_rust_platforms)
            branches[condition] = value
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
