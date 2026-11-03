"""Providers for Miri rules."""

MiriCrateInfo = provider(
    doc = "A Rust crate compiled by Miri-as-rustc for use by miri_test.",
    fields = {
        "crate_info": "The source crate's rules_rust CrateInfo.",
        "host": "Compiled crate struct for Miri host-mode rustc/proc-macro use.",
        "target": "Compiled crate struct for Miri target-mode use.",
    },
)

# TODO(https://github.com/bazelbuild/bazel/issues/32207): Declare field types on
# the provider when every supported Bazel accepts typed provider fields.
MiriSysrootInfo = provider(
    doc = "A sysroot prepared for Miri execution.",
    fields = {
        "sysroot": "The sysroot directory artifact.",  # type: File
        "target_triple": "The target triple the sysroot was built for.",  # type: str
    },
)
