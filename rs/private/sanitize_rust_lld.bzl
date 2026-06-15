"""Strips the leaked upstream CI LC_RPATH from the macOS rust-lld binary.

Upstream macOS rust-lld ships an absolute LC_RPATH pointing at the Rust
project's CI builder (/Users/runner/work/rust/rust/build/<triple>/llvm/lib).
It is inert today (rust-lld has no @rpath dependencies) but leaks the upstream
build layout and is flagged by relocatability/provenance scanners.

This is a build action rather than repository-rule work: a repository rule runs
on the machine driving Bazel -- often a non-macOS scheduler under remote
execution -- and cannot re-sign a Mach-O binary. The action runs wherever
rust-lld is consumed (a dev laptop or a macOS remote-execution worker), keyed to
the macOS execution platform by the caller. It uses Apple's install_name_tool,
which re-signs the ad-hoc signature that Apple Silicon requires after a load
command is removed; using it instead of @llvm//tools avoids forcing an LLVM
download onto every downstream consumer. All tools are referenced by absolute
path so the action does not depend on the worker's PATH.
"""

# Positional args ($1 src, $2 out, $3 leaked rpath) keep all quoting in Starlark
# rather than in a BUILD-embedded command string.
_SANITIZE_CMD = """\
set -euo pipefail
src="$1"
out="$2"
leaked_rpath="$3"
/bin/cp -p "$src" "$out"
/bin/chmod u+w "$out"
if /usr/bin/otool -l "$out" | /usr/bin/grep -Fq "path $leaked_rpath "; then
    /usr/bin/install_name_tool -delete_rpath "$leaked_rpath" "$out"
fi
/bin/chmod +x "$out"
"""

def _sanitize_rust_lld_impl(ctx):
    out = ctx.actions.declare_file("{}/rust-lld".format(ctx.label.name))
    leaked_rpath = "/Users/runner/work/rust/rust/build/{}/llvm/lib".format(ctx.attr.target_triple)
    ctx.actions.run_shell(
        inputs = [ctx.file.src],
        outputs = [out],
        command = _SANITIZE_CMD,
        arguments = [ctx.file.src.path, out.path, leaked_rpath],
        mnemonic = "SanitizeRustLld",
        progress_message = "Stripping leaked rpath from %{input}",
    )
    return [DefaultInfo(files = depset([out]))]

sanitize_rust_lld = rule(
    implementation = _sanitize_rust_lld_impl,
    doc = "Emits rust-lld with the leaked upstream CI LC_RPATH removed (macOS only).",
    attrs = {
        "src": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "The upstream rust-lld binary to sanitize.",
        ),
        "target_triple": attr.string(
            mandatory = True,
            doc = "Exec triple whose leaked CI build path should be stripped.",
        ),
    },
)
