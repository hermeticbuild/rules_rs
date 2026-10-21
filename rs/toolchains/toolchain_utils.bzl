"""Shared helpers for toolchain generation."""

def rust_version_channel(version):
    # type: (str) -> Literal["nightly", "beta", "stable"]
    if version.startswith("nightly"):
        return "nightly"
    if version.startswith("beta"):
        return "beta"
    return "stable"

def sanitize_triple(triple_str):
    # type: (str) -> str
    return triple_str.replace("-", "_").replace(".", "_")

def sanitize_version(version):
    # type: (str) -> str
    return version.replace("/", "_").replace(".", "_").replace("-", "_")
