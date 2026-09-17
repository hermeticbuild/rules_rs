load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":cfg_parser.bzl", "cfg_matches", "cfg_matches_expr_for_cfg_attrs", "cfg_matches_expr_for_triples", "triple_to_cfg_attrs")

def _cfg(expr):
    return "cfg(%s)" % expr

def _cfg_parser_smoke_test_impl(ctx):
    env = unittest.begin(ctx)

    mac = "aarch64-apple-darwin"
    linux_gnu = "x86_64-unknown-linux-gnu"
    linux_musl = "aarch64-unknown-linux-musl"
    win = "x86_64-pc-windows-msvc"
    win_gnu = "x86_64-pc-windows-gnu"
    win_gnullvm = "aarch64-pc-windows-gnullvm"
    wasm = "wasm32-unknown-unknown"
    riscv32imac = "riscv32imac-unknown-none-elf"
    riscv64gc = "riscv64gc-unknown-linux-musl"

    # MacOS facts facts
    asserts.true(env, cfg_matches(_cfg("unix"), mac))
    asserts.true(env, cfg_matches(_cfg('target_os = "macos"'), mac))
    asserts.true(env, cfg_matches(_cfg('target_arch = "aarch64"'), mac))
    asserts.true(env, cfg_matches(_cfg('target_family = "unix"'), mac))
    asserts.false(env, cfg_matches(_cfg("windows"), mac))

    # Linux facts
    asserts.true(env, cfg_matches(_cfg("unix"), linux_gnu))
    asserts.true(env, cfg_matches(_cfg('target_os = "linux"'), linux_gnu))
    asserts.true(env, cfg_matches(_cfg('target_env = "gnu"'), linux_gnu))
    asserts.false(env, cfg_matches(_cfg('target_env = "musl"'), linux_gnu))
    asserts.true(env, cfg_matches(_cfg('target_env = "musl"'), linux_musl))

    # Windows facts
    asserts.true(env, cfg_matches(_cfg("windows"), win))
    asserts.false(env, cfg_matches(_cfg("unix"), win))
    asserts.true(env, cfg_matches(_cfg('target_env = "msvc"'), win))
    asserts.true(env, cfg_matches(_cfg('target_family = "windows"'), win))
    asserts.true(env, cfg_matches(_cfg('target_pointer_width = "64"'), win))
    asserts.true(env, cfg_matches(_cfg('target_env = "gnu"'), win_gnu))
    asserts.true(env, cfg_matches(_cfg('target_env = "gnullvm"'), win_gnullvm))

    # Wasm facts
    asserts.true(env, cfg_matches(_cfg("wasm"), wasm))
    asserts.false(env, cfg_matches(_cfg("unix"), wasm))
    asserts.false(env, cfg_matches(_cfg("windows"), wasm))
    asserts.true(env, cfg_matches(_cfg('target_arch = "wasm32"'), wasm))
    asserts.true(env, cfg_matches(_cfg('target_os = "unknown"'), wasm))
    asserts.true(env, cfg_matches(_cfg('target_family = "wasm"'), wasm))
    asserts.true(env, cfg_matches(_cfg('target_pointer_width = "32"'), wasm))

    # RISC-V triples include ISA extensions in the architecture component, but
    # Rust exposes the register width through cfg(target_arch).
    asserts.true(env, cfg_matches(_cfg('target_arch = "riscv32"'), riscv32imac))
    asserts.true(env, cfg_matches(_cfg('target_pointer_width = "32"'), riscv32imac))
    asserts.false(env, cfg_matches(_cfg('target_arch = "riscv32imac"'), riscv32imac))
    asserts.true(env, cfg_matches(_cfg('target_arch = "riscv64"'), riscv64gc))
    asserts.true(env, cfg_matches(_cfg('target_pointer_width = "64"'), riscv64gc))
    asserts.false(env, cfg_matches(_cfg('target_arch = "riscv64gc"'), riscv64gc))

    # Combinators
    asserts.false(env, cfg_matches(_cfg("any()"), mac))
    asserts.true(env, cfg_matches(_cfg("not(any())"), mac))
    asserts.true(env, cfg_matches(_cfg("all()"), mac))
    asserts.false(env, cfg_matches(_cfg("not(all())"), mac))
    asserts.false(env, cfg_matches(_cfg("false"), mac))
    asserts.true(env, cfg_matches(_cfg("true"), mac))
    asserts.true(env, cfg_matches(_cfg("any(true)"), mac))
    asserts.true(env, cfg_matches(_cfg("any(true, false)"), mac))
    asserts.true(env, cfg_matches(_cfg("all(true)"), mac))
    asserts.false(env, cfg_matches(_cfg("all(true, false)"), mac))
    asserts.true(env, cfg_matches(_cfg('feature = "serde"'), mac, features = ["serde"]))
    asserts.false(env, cfg_matches(_cfg('feature = "serde"'), mac))
    asserts.true(env, cfg_matches(_cfg('target_feature = "sse2"'), linux_gnu))
    asserts.false(env, cfg_matches(_cfg('target_feature = "sse2"'), mac))

    triples = [mac, linux_gnu, linux_musl, win, win_gnu, win_gnullvm, wasm, riscv32imac, riscv64gc]

    results = cfg_matches_expr_for_triples(_cfg('all(unix, any(target_env = "gnu", target_env = "musl"))'), triples)
    asserts.equals(env, results.matches, [linux_gnu, linux_musl, riscv64gc])

    results = cfg_matches_expr_for_triples(
        _cfg('any(target_arch = "aarch64", target_arch = "x86_64", target_arch = "x86")'),
        triples,
    )
    asserts.equals(env, results.matches, [mac, linux_gnu, linux_musl, win, win_gnu, win_gnullvm])

    # Cargo dependencies can target a specific triple instead of a cfg expression.
    results = cfg_matches_expr_for_triples(win_gnullvm, triples)
    asserts.equals(env, results.matches, [win_gnullvm])

    results = cfg_matches_expr_for_triples(_cfg('all(target_os = "windows", any(target_env = "msvc", target_env = "gnu", target_env = "gnullvm"))'), triples)
    asserts.equals(env, results.matches, [win, win_gnu, win_gnullvm])

    results = cfg_matches_expr_for_triples(_cfg('feature = "serde"'), triples, features = ["serde"])
    asserts.equals(env, results.matches, triples)

    results = cfg_matches_expr_for_triples(_cfg('feature = "serde"'), triples)
    asserts.equals(env, results.matches, [])

    info = cfg_matches_expr_for_cfg_attrs(
        _cfg('all(feature = "serde", target_feature = "sse2")'),
        [triple_to_cfg_attrs(linux_gnu)],
    )
    asserts.true(env, info.uses_feature_cfg)
    asserts.equals(env, info.matches, [])

    info = cfg_matches_expr_for_cfg_attrs(win_gnullvm, [triple_to_cfg_attrs(win_gnullvm)])
    asserts.false(env, info.uses_feature_cfg)
    asserts.equals(env, info.matches, [win_gnullvm])

    info = cfg_matches_expr_for_cfg_attrs(
        _cfg('target_feature = "sse2"'),
        [triple_to_cfg_attrs(linux_gnu)],
    )
    asserts.false(env, info.uses_feature_cfg)
    asserts.equals(env, info.matches, [linux_gnu])

    return unittest.end(env)

cfg_parser_smoke_test = unittest.make(_cfg_parser_smoke_test_impl)

def _assert_attrs(env, triple, expected):
    """Asserts the named subset of `triple_to_cfg_attrs(triple)`.

    Expected values are `rustc --print cfg --target <triple>` output.
    """
    actual = triple_to_cfg_attrs(triple)
    for key, want in expected.items():
        asserts.equals(env, want, actual[key], "%s: %s" % (triple, key))

def _triple_normalization_test_impl(ctx):
    env = unittest.begin(ctx)

    # 32-bit Android: a 3-part triple whose third component is an OS with the
    # ABI glued onto it. Read positionally it yields target_os "androideabi",
    # which is neither "android" nor unix, so every cfg(unix) and
    # cfg(target_os = "android") dependency is dropped.
    for triple in ["armv7-linux-androideabi", "arm-linux-androideabi"]:
        _assert_attrs(env, triple, {
            "target_arch": "arm",
            "target_os": "android",
            "target_family": "unix",
            "target_abi": "eabi",
            "target_vendor": "unknown",
            "target_pointer_width": "32",
            "unix": True,
        })
        asserts.true(env, cfg_matches(_cfg("unix"), triple))
        asserts.true(env, cfg_matches(_cfg('target_os = "android"'), triple))
        asserts.true(env, cfg_matches(_cfg('target_arch = "arm"'), triple))

    # 64-bit Android is 3-part too, but its third component is a plain OS.
    _assert_attrs(env, "aarch64-linux-android", {
        "target_arch": "aarch64",
        "target_os": "android",
        "target_family": "unix",
        "target_vendor": "unknown",
        "unix": True,
    })

    # Bare-metal Arm: the third component is an ABI, so the OS sits in the
    # vendor slot and the triple names no vendor at all.
    _assert_attrs(env, "thumbv7m-none-eabi", {
        "target_arch": "arm",
        "target_os": "none",
        "target_family": "",
        "target_abi": "eabi",
        "target_vendor": "unknown",
        "target_pointer_width": "32",
        "unix": False,
    })
    _assert_attrs(env, "thumbv7em-none-eabihf", {
        "target_arch": "arm",
        "target_os": "none",
        "target_abi": "eabihf",
    })

    # Apple spells 64-bit Arm arm64/arm64e; rustc reports aarch64.
    _assert_attrs(env, "arm64e-apple-ios", {
        "target_arch": "aarch64",
        "target_os": "ios",
        "target_pointer_width": "64",
    })
    _assert_attrs(env, "arm64_32-apple-watchos", {
        "target_arch": "aarch64",
        "target_pointer_width": "64",
    })

    # ARM64EC is a distinct Windows architecture, not an Apple spelling of
    # AArch64.
    _assert_attrs(env, "arm64ec-pc-windows-msvc", {
        "target_arch": "arm64ec",
        "target_os": "windows",
        "target_pointer_width": "64",
    })

    # Remaining arch spellings that differ from rustc's target_arch.
    _assert_attrs(env, "i686-unknown-linux-gnu", {
        "target_arch": "x86",
        "target_pointer_width": "32",
    })
    _assert_attrs(env, "bpfel-unknown-none", {"target_arch": "bpf"})

    # Endianness is read from the RAW arch, which is where the byte order is
    # spelled — normalizing first would make these two indistinguishable.
    _assert_attrs(env, "bpfeb-unknown-none", {
        "target_arch": "bpf",
        "target_endian": "big",
    })
    _assert_attrs(env, "powerpc64le-unknown-linux-gnu", {
        "target_arch": "powerpc64",
        "target_endian": "little",
    })
    _assert_attrs(env, "powerpc64-unknown-linux-gnu", {
        "target_arch": "powerpc64",
        "target_endian": "big",
    })

    # "eabi" is a substring of "eabihf"; the longer ABI must win.
    _assert_attrs(env, "armv7-unknown-linux-gnueabihf", {
        "target_arch": "arm",
        "target_abi": "eabihf",
    })

    # Unchanged: 4-part triples stay positional.
    _assert_attrs(env, "x86_64-unknown-linux-gnu", {
        "target_arch": "x86_64",
        "target_vendor": "unknown",
        "target_os": "linux",
        "target_env": "gnu",
        "target_family": "unix",
    })
    _assert_attrs(env, "aarch64-apple-darwin", {
        "target_arch": "aarch64",
        "target_vendor": "apple",
        "target_os": "macos",
    })
    _assert_attrs(env, "x86_64-pc-windows-msvc", {
        "target_arch": "x86_64",
        "target_vendor": "pc",
        "target_os": "windows",
        "target_family": "windows",
        "windows": True,
    })

    return unittest.end(env)

triple_normalization_test = unittest.make(_triple_normalization_test_impl)

def cfg_parser_tests():
    return unittest.suite(
        "cfg_parser_tests",
        cfg_parser_smoke_test,
        triple_normalization_test,
    )
