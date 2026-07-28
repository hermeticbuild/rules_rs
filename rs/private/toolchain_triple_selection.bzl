"""Helpers for resolving toolchain execution and target triples."""

load(
    "//rs/platforms:triples.bzl",
    "ALL_TARGET_TRIPLES",
    "SUPPORTED_EXEC_TRIPLES",
    "SUPPORTED_TIER_1_AND_2_TRIPLES",
)

def _resolve_triples(requested, defaults, supported, kind):
    if not requested:
        return defaults

    resolved = []
    seen = {}
    for triple in requested:
        if triple not in supported:
            fail("{} triple {} is not supported".format(kind, triple))
        if triple not in seen:
            seen[triple] = None
            resolved.append(triple)

    return resolved

def resolve_toolchain_execs(execs):
    """Returns validated execution triples, using the full default when empty."""
    return _resolve_triples(execs, SUPPORTED_EXEC_TRIPLES, SUPPORTED_EXEC_TRIPLES, "Execution")

def resolve_toolchain_targets(targets):
    """Returns validated target triples, using the full default when empty."""
    return _resolve_triples(targets, ALL_TARGET_TRIPLES, ALL_TARGET_TRIPLES, "Target")

def add_version_triples(triples_by_version, version, triples):
    """Adds triples to a version-keyed dict while retaining declaration order."""
    resolved = list(triples_by_version.get(version, []))
    seen = {triple: None for triple in resolved}
    for triple in triples:
        if triple not in seen:
            seen[triple] = None
            resolved.append(triple)
    triples_by_version[version] = resolved

def downloadable_stdlib_targets(targets):
    """Returns targets whose standard libraries are distributed as archives."""
    return [target for target in targets if target in SUPPORTED_TIER_1_AND_2_TRIPLES]
