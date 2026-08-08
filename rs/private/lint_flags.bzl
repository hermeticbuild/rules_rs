"""Converts parsed Cargo.toml lint sections into rustc/clippy/rustdoc flags."""

_VALID_LEVELS = ["allow", "warn", "deny", "forbid"]

def _parse_lint(value):
    """Parses a lint value into (level, priority).

    A lint can be either a simple string ("allow") or a table
    ({"level": "deny", "priority": -1}).
    """
    if type(value) == "string":
        if value not in _VALID_LEVELS:
            fail("Invalid lint level: %s" % value)
        return value, 0

    level = value.get("level")
    if not level or level not in _VALID_LEVELS:
        fail("Invalid lint level: %s" % value)
    priority = value.get("priority", 0)
    return level, priority

def _format_flags(lints, prefix):
    """Converts a dict of lint_name -> lint_value into sorted CLI flags.

    Lints are sorted by (priority, name) so that lower-priority lints come
    first and can be overridden by higher-priority ones, matching Cargo's
    behavior.
    """
    if not lints:
        return []

    entries = []
    for name, value in lints.items():
        level, priority = _parse_lint(value)
        entries.append((priority, name, level))

    entries = sorted(entries, key = lambda e: (e[0], e[1]))

    flags = []
    for _, name, level in entries:
        if prefix:
            flags.append("--%s=%s::%s" % (level, prefix, name))
        else:
            flags.append("--%s=%s" % (level, name))
    return flags

def cargo_toml_lint_flags(cargo_toml_json):
    """Extracts effective package lint flags from a parsed Cargo.toml.

    Args:
        cargo_toml_json: The parsed Cargo.toml as a dict (from toml2json).

    Returns:
        A struct with rustc_lint_flags, clippy_lint_flags, and
        rustdoc_lint_flags, each a list of strings.
    """
    lints = cargo_toml_json.get("lints", {})

    if lints.get("workspace") == True:
        lints = cargo_toml_json.get("workspace", {}).get("lints", {})

    if not lints:
        return struct(
            rustc_lint_flags = [],
            clippy_lint_flags = [],
            rustdoc_lint_flags = [],
        )

    return struct(
        rustc_lint_flags = _format_flags(lints.get("rust", {}), ""),
        clippy_lint_flags = _format_flags(lints.get("clippy", {}), "clippy"),
        rustdoc_lint_flags = _format_flags(lints.get("rustdoc", {}), "rustdoc"),
    )

def workspace_cargo_toml_lint_flags(cargo_toml_json):
    """Extracts workspace lint policy from a parsed Cargo.toml.

    Args:
        cargo_toml_json: The parsed workspace Cargo.toml as a dict (from toml2json).

    Returns:
        A struct with rustc_lint_flags, clippy_lint_flags, and
        rustdoc_lint_flags, each a list of strings.
    """
    lints = cargo_toml_json.get("workspace", {}).get("lints", {})

    if not lints:
        return struct(
            rustc_lint_flags = [],
            clippy_lint_flags = [],
            rustdoc_lint_flags = [],
        )

    return struct(
        rustc_lint_flags = _format_flags(lints.get("rust", {}), ""),
        clippy_lint_flags = _format_flags(lints.get("clippy", {}), "clippy"),
        rustdoc_lint_flags = _format_flags(lints.get("rustdoc", {}), "rustdoc"),
    )
