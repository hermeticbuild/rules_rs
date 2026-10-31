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

_CLANG_CL_PARAMETER_FLAGS = CLANG_PARAMETER_FLAGS + (
    "-Xpreprocessor",
    "-include-pch",
    "-ivfsoverlay",
    "-vfsoverlay",
)
_MSVC_PARAMETER_FLAGS = ("/D", "/U", "/I", "/FI", "/imsvc", "/external:I")

def clang_cl_user_flags(flags):
    """Makes GNU-style user flags usable with the clang-cl driver.

    Keep native include options native: in particular, /imsvc is not an alias
    for -isystem. Forward GNU-only options with /clang:. Options with equivalent
    spellings share one stream so mixing spellings preserves their ordering.

    Args:
      flags: The rust_bindgen clang_flags attribute.

    Returns:
      Flags suitable for the clang-cl user_compile_flags variable.
    """
    result = []
    operand_prefix = None
    for original_flag in normalize_msvc_compile_flags(flags, preserve_imsvc = True):
        if operand_prefix != None:
            # An operand can look like an option, including an absolute path.
            flag = original_flag
            if operand_prefix and flag.startswith(operand_prefix):
                flag = flag[len(operand_prefix):]
            result.append(operand_prefix + flag)
            operand_prefix = None
            continue

        flag = original_flag.removeprefix("/clang:")
        if flag.startswith("-isystem") and not flag.startswith("-isystem-"):
            # These are exact aliases in Clang's option table. Unlike generic
            # /clang: forwarding, they keep order with /external:I and /FI.
            result.append("/external:I" + flag[len("-isystem"):])
            if flag == "-isystem":
                operand_prefix = ""
        elif flag == "-include" or (flag.startswith("-include") and not flag.startswith("-include-")):
            result.append("/FI" + flag[len("-include"):])
            if flag == "-include":
                operand_prefix = ""
        elif flag.startswith(("/", "-D", "-U", "-I", "-x", "--target=", "-resource-dir=")) or flag in ("-target", "--target", "-resource-dir"):
            # -D/-U/-I already work in CL mode. Do not forward them: clang-cl
            # appends /clang: arguments after native ones, changing precedence.
            # Keep target/language visible to bindgen's own argument inspection.
            result.append("-target" if flag == "--target" else flag)
            if flag in _CLANG_CL_PARAMETER_FLAGS + _MSVC_PARAMETER_FLAGS:
                operand_prefix = ""
        else:
            result.append("/clang:" + flag)
            if flag in _CLANG_CL_PARAMETER_FLAGS:
                operand_prefix = "/clang:"
    return result

def clang_cl_compile_flags(flags, user_flags = []):
    """Preserves the target compiler's native frontend options for libclang.

    Args:
      flags: The clang-cl C++ toolchain command line (including adapted user flags).
      user_flags: Adapted clang_flags whose explicit diagnostic policy is retained.

    Returns:
      A CL-mode command line without compile outputs or compiler-only plugins.
    """
    result = ["--driver-mode=cl"]
    skip_until = 0
    for index, original_flag in enumerate(flags):
        if index < skip_until:
            continue
        flag = original_flag.removeprefix("/clang:")

        # Compiler warning policy belongs to compilation, not binding generation
        # with a potentially different libclang version. Keep warnings visible;
        # only inherit -Werror when the bindgen caller explicitly requests it.
        if (flag in ("/WX", "-WX") or flag.startswith("-Werror")) and original_flag not in user_flags:
            continue
        if flag == "-Xclang" and index + 1 < len(flags):
            argument = flags[index + 1].removeprefix("/clang:")
            if argument in ("-fno-cxx-modules", "-fexperimental-optimized-noescape", "-fmodule-map-file-home-is-cwd"):
                skip_until = index + 2
                continue
            if argument in ("-load", "-plugin", "-add-plugin") or argument.startswith("-plugin-arg-"):
                skip_until = index + 2
                if index + 3 < len(flags) and flags[index + 2].removeprefix("/clang:") == "-Xclang":
                    skip_until = index + 4
                continue

        # libclang builds an AST, not an object/PCH or profiling artifact. Leave
        # ABI, language, preprocessor and VFS options to the compiler itself.
        if flag in ("/c", "/nologo", "-c", "-S", "-E", "/E", "/EP", "/P") or flag.startswith(("-ftime-trace", "-fplugin=")):
            continue
        if flag in ("-o", "/Fo", "/Fd", "/Fi", "/Fa", "/Fe"):
            skip_until = index + 2
            continue
        if flag.startswith(("/Fo", "/Fd", "/Fi", "/Fa", "/Fe")):
            continue

        # bindgen 0.72 inspects the unwrapped target before invoking libclang.
        result.append(flag if flag.startswith("--target=") or flag == "-target" else original_flag)
        if flag in _CLANG_CL_PARAMETER_FLAGS + _MSVC_PARAMETER_FLAGS and index + 1 < len(flags):
            result.append(flags[index + 1].removeprefix("/clang:") if flag == "-target" else flags[index + 1])
            skip_until = index + 2
    return result

def normalize_msvc_compile_flags(compile_flags, preserve_imsvc = False):
    """Converts clang-cl preprocessing flags to Clang driver flags.

    Args:
      compile_flags: clang-cl compile flags.
      preserve_imsvc: Keep /imsvc for consumers using native CL driver mode.

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
        ("/imsvc", "/imsvc" if preserve_imsvc else "-isystem"),
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
    copy_next_for = None
    copy_next_was_forwarded = False
    for original_flag in compile_flags:
        flag = original_flag
        lowercase_flag = flag.lower()
        if copy_next_for:
            if (copy_next_for == "-Xclang" or (preserve_imsvc and copy_next_was_forwarded)) and lowercase_flag.startswith("/clang:"):
                flag = flag[len("/clang:"):]
            result.append(flag)
            copy_next_for = None
            continue

        forwarded = lowercase_flag.startswith("/clang:")
        if forwarded:
            flag = flag[len("/clang:"):]
            lowercase_flag = flag.lower()

        # A parameter may look like another option, for example /Users/include.
        if flag in (_CLANG_CL_PARAMETER_FLAGS if preserve_imsvc else CLANG_PARAMETER_FLAGS):
            result.append(flag)
            copy_next_for = flag
            copy_next_was_forwarded = forwarded
            continue

        # clang-cl recognizes these complete options before considering joined
        # /D, /U, and /I arguments.
        if lowercase_flag.startswith(non_preprocessor_options):
            result.append(flag)
            continue

        normalized = False
        for prefix, replacement in prefixes:
            if lowercase_flag == prefix:
                result.append(replacement)
                copy_next_for = replacement
                copy_next_was_forwarded = forwarded
                normalized = True
                break
            if lowercase_flag.startswith(prefix):
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

    return result
