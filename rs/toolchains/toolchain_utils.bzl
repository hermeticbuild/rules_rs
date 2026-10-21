"""Shared helpers for toolchain generation."""

def sanitize_triple(triple_str):
    # type: (str) -> str
    return triple_str.replace("-", "_").replace(".", "_")

def sanitize_version(version):
    # type: (str) -> str
    return version.replace("/", "_").replace(".", "_").replace("-", "_")
