"""Module extension for configuring rules_rs Rust toolchains."""

load("@rules_rust//rust/platform:triple.bzl", _parse_triple = "triple")
load(
    "@rules_rust//rust/private:repository_utils.bzl",
    "DEFAULT_STATIC_RUST_URL_TEMPLATES",
    "check_version_valid",
    "produce_tool_suburl",
)
load("//rs/experimental/miri/private:miri_repository.bzl", "miri_repository")
load("//rs/platforms:triples.bzl", "SUPPORTED_EXEC_TRIPLES", "SUPPORTED_TIER_1_AND_2_TRIPLES")
load("//rs/private:cargo_repository.bzl", "cargo_repository")
load("//rs/private:clippy_repository.bzl", "clippy_repository")
load("//rs/private:host_tools_repository.bzl", "host_tools_repository")
load("//rs/private:rust_analyzer_repository.bzl", "rust_analyzer_repository")
load("//rs/private:rust_src_repository.bzl", "rust_src_repository")
load("//rs/private:rustc_repository.bzl", "rustc_repository")
load("//rs/private:rustc_src_repository.bzl", "rustc_src_repository")
load("//rs/private:rustfmt_repository.bzl", "rustfmt_repository")
load("//rs/private:stdlib_repository.bzl", "stdlib_repository")
load("//rs/private:toolchains_repository.bzl", "toolchains_repository")
load("//rs/toolchains:toolchain_utils.bzl", "sanitize_triple", "sanitize_version")

_DEFAULT_RUSTC_VERSION = "1.92.0"
_DEFAULT_EDITION = "2021"
_DEFAULT_TOOLCHAIN_REPO_NAME = "default_rust_toolchains"

def _normalize_os_name(os_name):
    os_name = os_name.lower()
    if os_name.startswith("mac os"):
        return "macos"
    if os_name.startswith("windows"):
        return "windows"
    return os_name

def _normalize_arch_name(arch):
    arch = arch.lower()
    if arch in ("amd64", "x86_64", "x64"):
        return "x86_64"
    if arch in ("aarch64", "arm64"):
        return "aarch64"
    return arch

def _sanitize_path_fragment(path):
    return path.replace("/", "_").replace(":", "_")

def _tool_extension(urls):
    url = urls[0] if urls else ""
    if url.endswith(".tar.gz"):
        return ".tar.gz"
    if url.endswith(".tar.xz"):
        return ".tar.xz"
    return ""

def _archive_path(tool_name, target_triple, version, iso_date):
    return produce_tool_suburl(tool_name, target_triple, version, iso_date) + _tool_extension(DEFAULT_STATIC_RUST_URL_TEMPLATES)

def _rustc_src_tool_suburl(version, iso_date = None):
    path = "rustc-{}-src".format(version)
    return iso_date + "/" + path if (iso_date and version in ("beta", "nightly")) else path

def _rustc_src_archive_path(version, iso_date):
    return _rustc_src_tool_suburl(version, iso_date) + _tool_extension(DEFAULT_STATIC_RUST_URL_TEMPLATES)

_TOOLCHAIN_TAG = tag_class(
    attrs = {
        "name": attr.string(
            doc = "Name of the generated toolchain repo.",
            default = _DEFAULT_TOOLCHAIN_REPO_NAME,
        ),
        "version": attr.string(
            doc = "Rust version (e.g. 1.86.0 or nightly/2025-04-03)",
            default = _DEFAULT_RUSTC_VERSION,
        ),
        "rustfmt_version": attr.string(
            doc = "Rustfmt version (e.g. 1.86.0 or nightly/2025-04-03)",
            default = "",
        ),
        "rust_analyzer_version": attr.string(
            doc = "Rust-analyzer version (e.g. 1.86.0 or nightly/2025-04-03)",
            default = "",
        ),
        "edition": attr.string(
            doc = "Default edition to apply to toolchains.",
            default = _DEFAULT_EDITION,
        ),
        "extra_rustc_flags": attr.string_list_dict(
            doc = "Additional rustc flags by target triple.",
        ),
        "extra_exec_rustc_flags": attr.string_list_dict(
            doc = "Additional rustc flags by exec triple.",
        ),
    },
)

def _parse_version(version):
    base_version = version
    iso_date = None
    if "/" in version:
        base_version, iso_date = version.split("/", 1)
    check_version_valid(base_version, iso_date)

    return base_version, iso_date

_EXPERIMENTAL_MIRI_TAG = tag_class(
    attrs = {
        "name": attr.string(
            default = "miri_toolchains",
            doc = "Name of the generated Miri toolchain repo.",
        ),
        "version": attr.string(
            mandatory = True,
            doc = "Miri version (e.g. nightly/2026-04-20).",
        ),
        "exec_triples": attr.string_list(
            default = SUPPORTED_EXEC_TRIPLES,
            doc = "Execution triples to declare Miri toolchains for.",
        ),
    },
)

def _miri_toolchains_repository_impl(rctx):
    rctx.file(
        "BUILD.bazel",
        """\
load("@rules_rs//rs/experimental/miri/private:declare_toolchains.bzl", "declare_miri_toolchains")

declare_miri_toolchains(
    version = {version},
    execs = {execs},
)
""".format(
            version = repr(rctx.attr.version),
            execs = repr(rctx.attr.execs),
        ),
    )

    return rctx.repo_metadata(reproducible = True)

_miri_toolchains_repository = repository_rule(
    implementation = _miri_toolchains_repository_impl,
    attrs = {
        "version": attr.string(mandatory = True),
        "execs": attr.string_list(mandatory = True),
    },
)

def _toolchains_impl(mctx):
    root_module_name = None
    for mod in mctx.modules:
        if mod.is_root:
            root_module_name = mod.name
            break

    version_tags = []
    had_tags = True
    for mod in mctx.modules:
        for tag in mod.tags.toolchain:
            version_tags.append(tag)

    if not version_tags:
        had_tags = False
        version_tags.append(struct(
            name = _DEFAULT_TOOLCHAIN_REPO_NAME,
            version = _DEFAULT_RUSTC_VERSION,
            rustfmt_version = "",
            rust_analyzer_version = "",
            edition = _DEFAULT_EDITION,
            extra_rustc_flags = {},
            extra_exec_rustc_flags = {},
        ))

    versions = set([])
    rustfmt_versions = set([])
    rust_analyzer_versions = set([])

    for tag in version_tags:
        versions.add(tag.version)
        rustfmt_versions.add(tag.rustfmt_version or tag.version)
        rust_analyzer_versions.add(tag.rust_analyzer_version or tag.version)

    miri_versions = set([])
    miri_repo_configs = {}
    miri_repo_tags = []
    for mod in mctx.modules:
        for tag in mod.tags.experimental_miri:
            _parse_version(tag.version)
            if not tag.exec_triples:
                fail("Miri toolchain repo {} must declare at least one exec triple".format(tag.name))
            for exec_triple in tag.exec_triples:
                if exec_triple not in SUPPORTED_EXEC_TRIPLES:
                    fail("Miri exec triple {} is not supported".format(exec_triple))

            existing = miri_repo_configs.get(tag.name)
            if existing and (
                existing.version != tag.version or
                existing.exec_triples != tag.exec_triples
            ):
                fail("Miri toolchain repo {} has conflicting tag configurations".format(tag.name))

            if not existing:
                miri_repo_configs[tag.name] = tag
                miri_repo_tags.append(tag)
                miri_versions.add(tag.version)

    rust_versions = versions | miri_versions

    existing_facts = getattr(mctx, "facts", {}) or {}
    pending_downloads = {}
    new_facts = {}

    def _request_archive_sha(archive_path, suburl):
        if archive_path in new_facts or archive_path in pending_downloads:
            return

        existing = existing_facts.get(archive_path)
        if existing:
            new_facts[archive_path] = existing
            return

        sha_filename = _sanitize_path_fragment(archive_path) + ".sha256"
        pending_downloads[archive_path] = struct(
            token = mctx.download(
                DEFAULT_STATIC_RUST_URL_TEMPLATES[0].format(suburl) + ".sha256",
                sha_filename,
                block = False,
            ),
            file = sha_filename,
        )

    def _request_sha(tool_name, version, iso_date, target_triple):
        _request_archive_sha(
            _archive_path(tool_name, target_triple, version, iso_date),
            produce_tool_suburl(tool_name, target_triple, version, iso_date),
        )

    # First pass: enqueue all sha downloads we don't already have.
    for version in rust_versions:
        base_version, iso_date = _parse_version(version)

        for triple in SUPPORTED_EXEC_TRIPLES:
            exec_triple = _parse_triple(triple)
            for tool_name in ["rustc", "cargo"]:
                _request_sha(tool_name, base_version, iso_date, exec_triple)
            if version in versions:
                _request_sha("clippy", base_version, iso_date, exec_triple)
            if version in miri_versions:
                _request_sha("miri", base_version, iso_date, exec_triple)

        for target_triple in SUPPORTED_TIER_1_AND_2_TRIPLES:
            _request_sha("rust-std", base_version, iso_date, _parse_triple(target_triple))

        _request_archive_sha(_rustc_src_archive_path(base_version, iso_date), _rustc_src_tool_suburl(base_version, iso_date))

    for version in rustfmt_versions:
        base_version, iso_date = _parse_version(version)

        for triple in SUPPORTED_EXEC_TRIPLES:
            exec_triple = _parse_triple(triple)

            # Rustfmt dynamically links against components in rustc, so we need both.
            for tool_name in ["rustc", "rustfmt"]:
                _request_sha(tool_name, base_version, iso_date, exec_triple)

    for version in rust_analyzer_versions:
        base_version, iso_date = _parse_version(version)

        _request_sha("rust-src", base_version, iso_date, None)

        for triple in SUPPORTED_EXEC_TRIPLES:
            exec_triple = _parse_triple(triple)

            for tool_name in ["rustc", "rust-analyzer"]:
                _request_sha(tool_name, base_version, iso_date, exec_triple)

    # Finish downloads and record facts.
    for archive_path, req in pending_downloads.items():
        req.token.wait()
        sha_text = mctx.read(req.file).strip()
        sha = sha_text.split(" ")[0] if sha_text else ""
        if not sha:
            fail("Could not parse sha256 for {}".format(archive_path))
        new_facts[archive_path] = sha

    def _sha_for(tool_name, version, iso_date, target_triple):
        archive_path = _archive_path(tool_name, target_triple, version, iso_date)
        return new_facts[archive_path]

    host_os = _normalize_os_name(mctx.os.name)
    host_arch = _normalize_arch_name(mctx.os.arch)
    host_cargo_repos = {}
    host_rustc_repos = {}

    for version in rust_versions | rustfmt_versions | rust_analyzer_versions:
        version_key = sanitize_version(version)
        base_version, iso_date = _parse_version(version)

        for triple in SUPPORTED_EXEC_TRIPLES:
            exec_triple = _parse_triple(triple)

            triple_suffix = exec_triple.system + "_" + exec_triple.arch
            rustc_name = "rustc_{}_{}".format(triple_suffix, version_key)

            rustc_repository(
                name = rustc_name,
                triple = triple,
                version = base_version,
                iso_date = iso_date,
                sha256 = _sha_for("rustc", base_version, iso_date, exec_triple),
            )

            if version in rust_versions:
                cargo_name = "cargo_{}_{}".format(triple_suffix, version_key)
                if exec_triple.arch == host_arch and exec_triple.system == host_os:
                    host_cargo_repos[version] = cargo_name
                    host_rustc_repos[version] = rustc_name

                cargo_repository(
                    name = cargo_name,
                    triple = triple,
                    version = base_version,
                    iso_date = iso_date,
                    sha256 = _sha_for("cargo", base_version, iso_date, exec_triple),
                )

            if version in versions:
                clippy_repository(
                    name = "clippy_{}_{}".format(triple_suffix, version_key),
                    triple = triple,
                    version = base_version,
                    iso_date = iso_date,
                    sha256 = _sha_for("clippy", base_version, iso_date, exec_triple),
                    rustc_sha256 = _sha_for("rustc", base_version, iso_date, exec_triple),
                )

            if version in miri_versions:
                miri_repository(
                    name = "miri_{}_{}".format(triple_suffix, version_key),
                    triple = triple,
                    version = base_version,
                    iso_date = iso_date,
                    sha256 = _sha_for("miri", base_version, iso_date, exec_triple),
                    rustc_sha256 = _sha_for("rustc", base_version, iso_date, exec_triple),
                )

        if version in rust_versions:
            for target_triple in SUPPORTED_TIER_1_AND_2_TRIPLES:
                stdlib_repository(
                    name = "rust_stdlib_{}_{}".format(sanitize_triple(target_triple), version_key),
                    triple = target_triple,
                    version = base_version,
                    iso_date = iso_date,
                    sha256 = _sha_for("rust-std", base_version, iso_date, _parse_triple(target_triple)),
                )

    for version in rustfmt_versions:
        version_key = sanitize_version(version)
        base_version, iso_date = _parse_version(version)

        for triple in SUPPORTED_EXEC_TRIPLES:
            exec_triple = _parse_triple(triple)
            triple_suffix = exec_triple.system + "_" + exec_triple.arch

            rustfmt_repository(
                name = "rustfmt_{}_{}".format(triple_suffix, version_key),
                triple = triple,
                version = base_version,
                iso_date = iso_date,
                sha256 = _sha_for("rustfmt", base_version, iso_date, exec_triple),
                rustc_sha256 = _sha_for("rustc", base_version, iso_date, exec_triple),
            )

    for version in rust_analyzer_versions:
        version_key = sanitize_version(version)
        base_version, iso_date = _parse_version(version)

        rust_src_repository(
            name = "rust_src_{}".format(version_key),
            version = base_version,
            iso_date = iso_date,
            sha256 = _sha_for("rust-src", base_version, iso_date, None),
        )

        for triple in SUPPORTED_EXEC_TRIPLES:
            exec_triple = _parse_triple(triple)
            triple_suffix = exec_triple.system + "_" + exec_triple.arch

            rust_analyzer_repository(
                name = "rust_analyzer_{}_{}".format(triple_suffix, version_key),
                triple = triple,
                version = base_version,
                iso_date = iso_date,
                sha256 = _sha_for("rust-analyzer", base_version, iso_date, exec_triple),
            )

    if len(host_cargo_repos) != len(rust_versions):
        fail("Could not find host Cargo repository for {}-{}".format(host_os, host_arch))
    if len(host_rustc_repos) != len(rust_versions):
        fail("Could not find host rustc repository for {}-{}".format(host_os, host_arch))
    host_exe_suffix = ".exe" if host_os == "windows" else ""
    host_cargo = "@{}//:bin/cargo{}".format(host_cargo_repos[version_tags[0].version], host_exe_suffix)

    for version in rust_versions:
        version_key = sanitize_version(version)
        base_version, iso_date = _parse_version(version)
        rustc_src_repository(
            name = "rustc_src_{}".format(version_key),
            version = base_version,
            iso_date = iso_date,
            sha256 = new_facts[_rustc_src_archive_path(base_version, iso_date)],
            cargo = "@{}//:bin/cargo{}".format(host_cargo_repos[version], host_exe_suffix),
            rustc = "@{}//:bin/rustc{}".format(host_rustc_repos[version], host_exe_suffix),
        )

    host_tools_repository(
        name = "rs_rust_host_tools",
        host_cargo = host_cargo,
    )

    # `rs_rust_host_tools` is an implementation detail of rules_rs itself.
    # Report it as a direct dependency only for the rules_rs root module so
    # user modules are not asked to import it.
    direct_deps = ["rs_rust_host_tools"] if root_module_name == "rules_rs" else []
    direct_dev_deps = []
    repo_configs = {}
    for tag in version_tags:
        repo_name = tag.name
        rustfmt_version = tag.rustfmt_version or tag.version
        rust_analyzer_version = tag.rust_analyzer_version or tag.version
        existing = repo_configs.get(repo_name)
        if existing and (
            existing.version != tag.version or
            (existing.rustfmt_version or existing.version) != rustfmt_version or
            (existing.rust_analyzer_version or existing.version) != rust_analyzer_version or
            existing.edition != tag.edition or
            existing.extra_rustc_flags != tag.extra_rustc_flags or
            existing.extra_exec_rustc_flags != tag.extra_exec_rustc_flags
        ):
            fail("Toolchain repo {} has conflicting tag configurations".format(repo_name))

        if not existing:
            repo_configs[repo_name] = tag
            toolchains_repository(
                name = repo_name,
                version = tag.version,
                rustfmt_version = rustfmt_version,
                rust_analyzer_version = rust_analyzer_version,
                edition = tag.edition,
                extra_rustc_flags = tag.extra_rustc_flags,
                extra_exec_rustc_flags = tag.extra_exec_rustc_flags,
            )
        is_dev_dependency = had_tags and mctx.is_dev_dependency(tag)
        if is_dev_dependency:
            if repo_name not in direct_dev_deps:
                direct_dev_deps.append(repo_name)
        elif repo_name not in direct_deps:
            direct_deps.append(repo_name)

    for tag in miri_repo_tags:
        if tag.name in repo_configs:
            fail("Miri toolchain repo {} conflicts with a Rust toolchain repo of the same name".format(tag.name))

        _miri_toolchains_repository(
            name = tag.name,
            version = tag.version,
            execs = tag.exec_triples,
        )

        if mctx.is_dev_dependency(tag):
            if tag.name not in direct_dev_deps:
                direct_dev_deps.append(tag.name)
        elif tag.name not in direct_deps:
            direct_deps.append(tag.name)

    kwargs = dict(
        reproducible = True,
        root_module_direct_deps = direct_deps,
        root_module_direct_dev_deps = direct_dev_deps,
    )

    if hasattr(mctx, "facts"):
        kwargs["facts"] = new_facts

    return mctx.extension_metadata(**kwargs)

toolchains = module_extension(
    implementation = _toolchains_impl,
    tag_classes = {
        "experimental_miri": _EXPERIMENTAL_MIRI_TAG,
        "toolchain": _TOOLCHAIN_TAG,
    },
)
