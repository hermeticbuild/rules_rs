"""Providers for Miri rules."""

MiriCrateInfo = provider(
    doc = "A Rust crate compiled by Miri-as-rustc for use by miri_test.",
    fields = {
        "crate_info": "The source crate's rules_rust CrateInfo.",
        "host": "Compiled crate struct for Miri host-mode rustc/proc-macro use.",
        "target": "Compiled crate struct for Miri target-mode use.",
    },
)

MiriSysrootInfo = provider(
    doc = "A sysroot prepared for Miri execution.",
    fields = {
        "sysroot": "The sysroot directory artifact.",
        "target_triple": "The target triple the sysroot was built for.",
    },
)
