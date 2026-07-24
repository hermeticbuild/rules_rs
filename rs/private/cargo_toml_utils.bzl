"""Helpers for interpreting decoded Cargo.toml manifests."""

def cargo_toml_is_proc_macro(cargo_toml_json):
    """Whether a decoded Cargo.toml declares a procedural macro library."""
    lib = cargo_toml_json.get("lib", {})
    if lib.get("proc-macro") or lib.get("proc_macro"):
        return True

    crate_types = lib.get("crate-type", lib.get("crate_type", [])) or []
    return "proc-macro" in crate_types
