load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(":cfg_parser.bzl", "cfg_matches", "cfg_matches_expr_for_triples", "cfg_matches_expr_for_cfg_attrs", "parse_rustc_cfg_output", "triple_to_cfg_attrs")

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

    triples = [mac, linux_gnu, linux_musl, win, win_gnu, win_gnullvm]

    results = cfg_matches_expr_for_triples(_cfg('all(unix, any(target_env = "gnu", target_env = "musl"))'), triples)
    asserts.equals(env, results.matches, [linux_gnu, linux_musl])

    results = cfg_matches_expr_for_triples(
        _cfg('any(target_arch = "aarch64", target_arch = "x86_64", target_arch = "x86")'),
        triples)
    asserts.equals(env, results.matches, triples)

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

def _parse_rustc_cfg_output_test_impl(ctx):
    env = unittest.begin(ctx)

    # Typical rustc --print=cfg output for x86_64-unknown-linux-gnu
    stdout = """\
debug_assertions
panic="unwind"
target_abi=""
target_arch="x86_64"
target_endian="little"
target_env="gnu"
target_family="unix"
target_os="linux"
target_pointer_width="64"
target_feature="sse2"
target_feature="sse3"
target_vendor="unknown"
unix
"""

    attrs = parse_rustc_cfg_output(stdout)

    asserts.equals(env, True, attrs["debug_assertions"])
    asserts.equals(env, True, attrs["unix"])
    asserts.equals(env, "unwind", attrs["panic"])
    asserts.equals(env, "x86_64", attrs["target_arch"])
    asserts.equals(env, "linux", attrs["target_os"])
    asserts.equals(env, "gnu", attrs["target_env"])
    asserts.equals(env, "unix", attrs["target_family"])
    asserts.equals(env, "little", attrs["target_endian"])
    asserts.equals(env, "64", attrs["target_pointer_width"])
    asserts.equals(env, ["sse2", "sse3"], attrs["target_feature"])
    asserts.equals(env, "unknown", attrs["target_vendor"])
    asserts.equals(env, "", attrs["target_abi"])

    # With custom --cfg flag: rustc --print=cfg --cfg=my_custom_flag
    stdout_with_custom = stdout + "my_custom_flag\n"
    attrs = parse_rustc_cfg_output(stdout_with_custom)
    asserts.equals(env, True, attrs["my_custom_flag"])
    asserts.equals(env, "linux", attrs["target_os"])

    # With custom --cfg key=value: rustc --print=cfg --cfg=my_feature=\"v2\"
    stdout_with_custom_kv = stdout + 'my_feature="v2"\n'
    attrs = parse_rustc_cfg_output(stdout_with_custom_kv)
    attrs["_triple"] = "x86_64-unknown-linux-gnu"
    asserts.equals(env, "v2", attrs["my_feature"])

    info = cfg_matches_expr_for_cfg_attrs(
        _cfg('target_feature = "sse2"'),
        [attrs],
    )
    asserts.equals(env, ["x86_64-unknown-linux-gnu"], info.matches)

    return unittest.end(env)

parse_rustc_cfg_output_test = unittest.make(_parse_rustc_cfg_output_test_impl)

def _custom_cfg_predicates_test_impl(ctx):
    env = unittest.begin(ctx)

    # Custom key=value predicate
    custom_attrs = {
        "_triple": "aarch64-apple-darwin",
        "true": True,
        "false": False,
        "target_os": "macos",
        "my_custom_flag": True,
        "my_feature": "v2",
        "target_feature": ["aes", "neon"],
    }

    # User's expression: not(my_custom_flag) when custom cfg is active → False
    info = cfg_matches_expr_for_cfg_attrs(
        _cfg("not(my_custom_flag)"),
        [custom_attrs],
    )
    asserts.false(env, info.uses_feature_cfg)
    asserts.equals(env, [], info.matches)

    info = cfg_matches_expr_for_cfg_attrs(
        _cfg('target_feature = "neon"'),
        [custom_attrs],
    )
    asserts.equals(env, ["aarch64-apple-darwin"], info.matches)

    # not(my_custom_flag) when custom cfg is NOT set → True (unknown predicates are False)
    custom_attrs_no_flag = dict(custom_attrs)
    custom_attrs_no_flag.pop("my_custom_flag")
    info = cfg_matches_expr_for_cfg_attrs(
        _cfg("not(my_custom_flag)"),
        [custom_attrs_no_flag],
    )
    asserts.false(env, info.uses_feature_cfg)
    asserts.equals(env, ["aarch64-apple-darwin"], info.matches)

    # Custom key=value predicate
    info = cfg_matches_expr_for_cfg_attrs(
        _cfg('my_feature = "v2"'),
        [custom_attrs],
    )
    asserts.equals(env, ["aarch64-apple-darwin"], info.matches)

    info = cfg_matches_expr_for_cfg_attrs(
        _cfg('my_feature = "v1"'),
        [custom_attrs],
    )
    asserts.equals(env, [], info.matches)

    # Nested combinators with custom predicate
    info = cfg_matches_expr_for_cfg_attrs(
        _cfg('all(target_os = "macos", any(my_custom_flag, my_feature = "v2"))'),
        [custom_attrs],
    )
    asserts.equals(env, ["aarch64-apple-darwin"], info.matches)

    return unittest.end(env)

custom_cfg_predicates_test = unittest.make(_custom_cfg_predicates_test_impl)

def cfg_parser_tests():
    return unittest.suite(
        "cfg_parser_tests",
        cfg_parser_smoke_test,
        parse_rustc_cfg_output_test,
        custom_cfg_predicates_test,
    )
