"""Rust toolchain version metadata helpers."""

def rust_toolchain_version_metadata(version):
    """Returns the metadata rules_rs can derive from a declared version.

    Channel toolchains intentionally keep the channel token as `version`.
    Consumers that need the exact compiler release must inspect the selected
    compiler because the date alone is not authoritative toolchain identity.
    """
    base_version = version
    iso_date = ""
    if "/" in version:
        base_version, iso_date = version.split("/", 1)

    channel = base_version if base_version in ("beta", "nightly") else "stable"
    if channel == "stable":
        version_parts = base_version.split(".")
        major = int(version_parts[0])
        minor = int(version_parts[1])
        has_rust_objcopy = major > 1 or (major == 1 and minor >= 84)
    elif channel == "nightly":
        has_rust_objcopy = iso_date >= "2024-11-07"
    else:
        has_rust_objcopy = iso_date >= "2024-11-27"
    return struct(
        channel = channel,
        has_rust_objcopy = has_rust_objcopy,
        iso_date = iso_date,
        version = base_version,
    )
