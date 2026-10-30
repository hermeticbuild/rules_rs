"""Clang argument helpers for bindgen."""

CLANG_PARAMETER_FLAGS = (
    "-D",
    "-F",
    "-I",
    "-U",
    "-Xclang",
    "-idirafter",
    "-iframework",
    "-imacros",
    "-include",
    "-iquote",
    "-isystem",
    "-isysroot",
    "-resource-dir",
    "-target",
    "-x",
    "--gcc-toolchain",
    "--no-system-header-prefix",
    "--sysroot",
    "--system-header-prefix",
    "--target",
)

def normalize_msvc_compile_flags(compile_flags):
    """Converts clang-cl preprocessing flags to Clang driver flags.

    Args:
      compile_flags: clang-cl compile flags.

    Returns:
      Compile flags accepted by the Clang driver.
    """
    non_preprocessor_options = (
        "/d1",
        "/d2",
        "/diagnostics:",
        "/doc",
        "/driver:",
        "/dynamicbase",
        "/ifc",
        "/incremental",
        "/interface",
        "/utf-8",
    )
    prefixes = (
        ("/external:i", "-isystem"),
        ("/imsvc", "-isystem"),
        ("/fi", "-include"),
        ("/d", "-D"),
        ("/u", "-U"),
        ("/i", "-I"),
    )
    runtime_libraries = {
        "/md": "dll",
        "/mdd": "dll_dbg",
        "/mt": "static",
        "/mtd": "static_dbg",
    }

    result = []
    msvc_include_positions = {}
    no_stdlibinc = False
    copy_next_for = None
    for original_flag in compile_flags:
        flag = original_flag
        lowercase_flag = flag.lower()
        if copy_next_for:
            if copy_next_for == "-Xclang" and lowercase_flag.startswith("/clang:"):
                flag = flag[len("/clang:"):]
            result.append(flag)
            copy_next_for = None
            continue

        if lowercase_flag.startswith("/clang:"):
            flag = flag[len("/clang:"):]
            lowercase_flag = flag.lower()

        if flag == "-nostdlibinc":
            no_stdlibinc = True

        # A parameter may look like another option, for example /Users/include.
        if flag in CLANG_PARAMETER_FLAGS:
            result.append(flag)
            copy_next_for = flag
            continue

        # clang-cl recognizes these complete options before considering joined
        # /D, /U, and /I arguments.
        if lowercase_flag.startswith(non_preprocessor_options):
            result.append(flag)
            continue

        normalized = False
        for prefix, replacement in prefixes:
            if lowercase_flag == prefix:
                if prefix == "/imsvc":
                    msvc_include_positions[len(result)] = True
                result.append(replacement)
                copy_next_for = replacement
                normalized = True
                break
            if lowercase_flag.startswith(prefix):
                if prefix == "/imsvc":
                    msvc_include_positions[len(result)] = True
                result.extend([replacement, flag[len(prefix):]])
                normalized = True
                break

        if not normalized:
            if lowercase_flag.startswith("/std:"):
                result.append("-std=" + lowercase_flag[len("/std:"):])
            elif lowercase_flag == "/tc":
                result.extend(["-x", "c"])
            elif lowercase_flag == "/tp":
                result.extend(["-x", "c++"])
            elif lowercase_flag in runtime_libraries:
                result.append("-fms-runtime-lib=" + runtime_libraries[lowercase_flag])
            else:
                result.append(flag)

    if no_stdlibinc:
        # clang-cl searches its builtin resource headers before /imsvc roots.
        # With automatic SDK discovery disabled, -idirafter preserves that
        # order in Clang driver mode. Do not apply this to native discovery:
        # its implicit SDK roots would then precede explicit /imsvc roots.
        # Converted roots precede any caller-supplied -idirafter directories.
        msvc_includes = []
        other_flags = []
        for index, flag in enumerate(result):
            if index in msvc_include_positions:
                msvc_includes.append("-idirafter")
            elif index - 1 in msvc_include_positions:
                msvc_includes.append(flag)
            else:
                other_flags.append(flag)
        return msvc_includes + other_flags

    return result
