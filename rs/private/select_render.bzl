"""Render platform-dependent values for generated BUILD files."""

load(":select_utils.bzl", "compute_select")

def _platform(triple, use_legacy_rules_rust_platforms):
    # type: (str, bool) -> str
    if use_legacy_rules_rust_platforms:
        return "@rules_rust//rust/platform:" + triple.replace("-musl", "-gnu").replace("-gnullvm", "-msvc")
    return "@rules_rs//rs/platforms/config:" + triple

def _format_branches(branches):
    # type: (Collection[tuple[str, str]]) -> str
    return """select({
        %s
    })""" % (
        ",\n        ".join(['"%s": %s' % branch for branch in branches])
    )

def render_select(non_platform_items, platform_items, use_legacy_rules_rust_platforms):
    # type: (Collection[object], Mapping[str, Collection[object]], bool) -> tuple[list[str], str]
    """Returns stringified common items and the remaining BUILD select expression.

    Args:
        non_platform_items: Values present on every platform.
        platform_items: Additional values keyed by target triple.
        use_legacy_rules_rust_platforms: Use rules_rust platform labels.

    Returns:
        The common string values and a select expression, or an empty string.
    """
    non_platform_items = [str(item) for item in non_platform_items]
    platform_items = {
        platform: [str(item) for item in items]
        for platform, items in platform_items.items()
    }
    common_items, branches = compute_select(non_platform_items, platform_items)
    common_items = list(common_items)

    if not branches:
        return common_items, ""

    branches = [(_platform(k, use_legacy_rules_rust_platforms), repr(v)) for k, v in branches.items()]
    branches.append(("//conditions:default", "[],"))

    return common_items, _format_branches(branches)

def render_select_build_script_env(platform_items, use_legacy_rules_rust_platforms):
    # type: (Mapping[str, str], bool) -> str
    """Renders serialized environment dictionaries as a BUILD select expression.

    Args:
        platform_items: Environment dictionary expressions keyed by target triple.
        use_legacy_rules_rust_platforms: Use rules_rust platform labels.

    Returns:
        A select expression with an empty dictionary default, or an empty string.
    """
    branches = [
        (_platform(triple, use_legacy_rules_rust_platforms), items)
        for triple, items in platform_items.items()
    ]

    if not branches:
        return ""

    branches.append(("//conditions:default", "{},"))

    return _format_branches(branches)
