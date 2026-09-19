"""Resolve toolchain declarations from the module graph."""

def _config(tag):
    return struct(
        name = tag.name,
        version = tag.version,
        rustfmt_version = tag.rustfmt_version or tag.version,
        rust_analyzer_version = tag.rust_analyzer_version or tag.version,
        edition = tag.edition,
        extra_rustc_flags = tag.extra_rustc_flags,
        extra_exec_rustc_flags = tag.extra_exec_rustc_flags,
        use_rust_redist = tag.use_rust_redist,
    )

def _highest_version(a, b, repo_name, attribute):
    if a == b:
        return a
    a_parts = a.split("/", 1)
    b_parts = b.split("/", 1)
    if a_parts[0] in ("beta", "nightly") or b_parts[0] in ("beta", "nightly"):
        if a_parts[0] == b_parts[0] and len(a_parts) == 2 and len(b_parts) == 2:
            return max(a, b)
        fail("Toolchain repo %s has incomparable %s values %r and %r; select a version in the root module or use different toolchain repo names" % (repo_name, attribute, a, b))
    return max([a, b], key = _stable_version_key)

def _stable_version_key(version):
    return tuple([int(part) for part in version.split(".")])

def _merge_configs(a, b):
    for attribute in ("extra_rustc_flags", "extra_exec_rustc_flags"):
        if getattr(a, attribute) != getattr(b, attribute):
            fail("Toolchain repo %s has conflicting %s; configure it in the root module or use different toolchain repo names" % (a.name, attribute))
    return struct(
        name = a.name,
        version = _highest_version(a.version, b.version, a.name, "version"),
        rustfmt_version = _highest_version(a.rustfmt_version, b.rustfmt_version, a.name, "rustfmt_version"),
        rust_analyzer_version = _highest_version(a.rust_analyzer_version, b.rust_analyzer_version, a.name, "rust_analyzer_version"),
        edition = max(a.edition, b.edition),
        extra_rustc_flags = a.extra_rustc_flags,
        extra_exec_rustc_flags = a.extra_exec_rustc_flags,
        use_rust_redist = a.use_rust_redist and b.use_rust_redist,
    )

def resolve_toolchain_configs(modules):
    """Return configurations by repo name, preferring root-module declarations.

    Args:
        modules: The module extension's module_ctx.modules.

    Returns:
        A dict of repo names to resolved configuration structs.
    """
    root_configs = {}
    for mod in modules:
        if not mod.is_root:
            continue
        for tag in mod.tags.toolchain:
            config = _config(tag)
            if tag.name in root_configs and root_configs[tag.name] != config:
                fail("Toolchain repo %s has conflicting tag configurations in the root module" % tag.name)
            root_configs[tag.name] = config

    configs = dict(root_configs)
    for mod in modules:
        if mod.is_root:
            continue
        for tag in mod.tags.toolchain:
            if tag.name in root_configs:
                continue
            config = _config(tag)
            if tag.name in configs:
                config = _merge_configs(configs[tag.name], config)
            configs[tag.name] = config
    return configs
