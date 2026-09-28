"""Declare complete Git workspace inputs across Bazel package boundaries."""

# Bound pathological symlink expansion without recursively evaluating Starlark.
_MAX_RESOURCE_DIRECTORIES = 10000
_PACKAGE_SOURCES = "__rules_rs_cargo_package_sources"
_ALL_SOURCES = "__rules_rs_cargo_sources"

def validate_resource_path(root, real, path, ancestors, is_dir):
    """Reject links outside the checkout and directory cycles before traversal."""
    if real != root and not real.startswith(root + "/"):
        fail("Git source link escapes its repository: " + path)
    if is_dir and real in ancestors:
        fail("Git source directory link cycle: " + path)

def workspace_resource_build_files(root, generated_build_files):
    """Inventory BUILD packages and validate that links stay within the checkout.

    Args:
        root: Repository root path.
        generated_build_files: Paths of BUILD files that will be generated.

    Returns:
        One BUILD file path per Bazel package, with BUILD.bazel taking precedence.
    """
    build_files = {path: None for path in generated_build_files}
    root_build = "BUILD.bazel" if "BUILD.bazel" in build_files or root.get_child("BUILD.bazel").exists or not root.get_child("BUILD").exists else "BUILD"
    build_files[root_build] = None
    real_root = str(root.realpath)
    pending = [(root, [real_root])]
    for _ in range(_MAX_RESOURCE_DIRECTORIES):
        if not pending:
            break
        directory, ancestors = pending.pop()
        for child in directory.readdir():
            if child.basename == ".git":
                continue
            if not child.exists:
                fail("Broken Git source link: " + str(child))
            real = str(child.realpath)
            validate_resource_path(real_root, real, str(child), ancestors, child.is_dir)
            if child.is_dir:
                pending.append((child, ancestors + [real]))
        for filename in ["BUILD.bazel", "BUILD"]:
            candidate = directory.get_child(filename)
            if candidate.exists:
                relative = str(candidate).removeprefix(str(root) + "/")
                build_files[relative] = None
                break
    if pending:
        fail("Git resource inventory exceeds %d directories" % _MAX_RESOURCE_DIRECTORIES)
    return [path for path in sorted(build_files) if not path.endswith("BUILD") or path + ".bazel" not in build_files]

def declare_workspace_resources(rctx, build_files):
    """Append package-local groups and a root group without replacing authored rules."""
    labels = []
    written = {}
    root_build = None
    for dest in build_files:
        real = str(rctx.path(dest).realpath)
        if real not in written:
            content = rctx.read(dest) if rctx.path(dest).exists else ""
            content += '\nfilegroup(name = %r, srcs = glob(["**"], exclude = [".git/**"]), visibility = ["//visibility:public"])\n' % _PACKAGE_SOURCES
            rctx.file(dest, content)
            written[real] = True
        directory = dest.removesuffix("BUILD.bazel").removesuffix("BUILD").removesuffix("/")
        labels.append("//" + directory + ":" + _PACKAGE_SOURCES)
        if not directory:
            root_build = dest
    rctx.file(root_build, rctx.read(root_build) + '\nfilegroup(name = %r, srcs = %r, visibility = ["//visibility:public"])\n' % (_ALL_SOURCES, labels))
