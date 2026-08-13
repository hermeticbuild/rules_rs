"""Repository rule for downloading bpf-linker."""

_BPF_LINKER_VERSION = "0.11.0"

_BPF_LINKER_ARCHIVES = {
    "aarch64-apple-darwin": "d3b1952971472334e3f3e76760c33a6a97f151af45b9b89a70e06d92e5bb4a75",
    "aarch64-pc-windows-gnullvm": "6ff367c572498f7b27e6ad902c303b6936fcd6bdee0bfd26d904f598ca849791",
    "aarch64-unknown-linux-musl": "d09ddd83303e9ab1443f51e0e284680154009646a3ce141c63d838ee61b73eb9",
    "x86_64-apple-darwin": "10eec9ff4397ec69d15e522ba6d579aecd8fc4cbec34d86cae7ea943bb5a9a55",
    "x86_64-pc-windows-gnullvm": "b6ff405d8f8469f8bb34c6e40c000d664bdf97f291cca8e76492658a9703ec6c",
    "x86_64-unknown-linux-musl": "10f62ba9ab7e544d538370552660efcb4f1a19153d5752bbf0f6b51f3bada450",
}

_BPF_LINKER_ARCHIVE_TRIPLES = {
    "aarch64-apple-darwin": "aarch64-apple-darwin",
    "aarch64-pc-windows-msvc": "aarch64-pc-windows-gnullvm",
    "aarch64-unknown-linux-gnu": "aarch64-unknown-linux-musl",
    "x86_64-apple-darwin": "x86_64-apple-darwin",
    "x86_64-pc-windows-msvc": "x86_64-pc-windows-gnullvm",
    "x86_64-unknown-linux-gnu": "x86_64-unknown-linux-musl",
}

BPF_LINKER_SUPPORTED_EXEC_TRIPLES = sorted(_BPF_LINKER_ARCHIVE_TRIPLES.keys())

def _bpf_linker_archive_triple(exec_triple):
    return _BPF_LINKER_ARCHIVE_TRIPLES.get(exec_triple)

def bpf_linker_repository_name(exec_triple):
    archive_triple = _bpf_linker_archive_triple(exec_triple)
    if not archive_triple:
        return None
    return "rs_bpf_linker_" + archive_triple.replace("-", "_")

def bpf_linker_binary_name(exec_triple):
    return "bpf-linker.exe" if "-windows-" in exec_triple else "bpf-linker"

def _bpf_linker_repository_impl(rctx):
    archive_triple = rctx.attr.archive_triple
    rctx.download_and_extract(
        url = "https://github.com/aya-rs/bpf-linker/releases/download/v{version}/bpf-linker-{triple}.tar.zst".format(
            version = _BPF_LINKER_VERSION,
            triple = archive_triple,
        ),
        sha256 = _BPF_LINKER_ARCHIVES[archive_triple],
    )
    rctx.file(
        "BUILD.bazel",
        'exports_files(["%s"])\n' % bpf_linker_binary_name(archive_triple),
    )

    return rctx.repo_metadata(reproducible = True)

_bpf_linker_repository = repository_rule(
    implementation = _bpf_linker_repository_impl,
    attrs = {
        "archive_triple": attr.string(
            mandatory = True,
            values = _BPF_LINKER_ARCHIVES.keys(),
        ),
    },
)

def declare_bpf_linker_repository(exec_triple):
    """Declares the pinned bpf-linker repository for a supported execution triple."""
    archive_triple = _bpf_linker_archive_triple(exec_triple)
    if not archive_triple:
        fail("bpf-linker is not available for execution triple {}".format(exec_triple))

    _bpf_linker_repository(
        name = bpf_linker_repository_name(exec_triple),
        archive_triple = archive_triple,
    )
