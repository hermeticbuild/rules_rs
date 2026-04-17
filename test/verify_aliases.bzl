def _verify_alias_impl(ctx):
    actual = ctx.attr.aliases.get(ctx.attr.expected_label)
    if actual != ctx.attr.expected_alias:
        fail(
            "Expected alias %r for %s, got %r from %r" % (
                ctx.attr.expected_alias,
                ctx.attr.expected_label,
                actual,
                ctx.attr.aliases,
            ),
        )

    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(out, "ok\n")
    return [DefaultInfo(files = depset([out]))]

verify_alias = rule(
    implementation = _verify_alias_impl,
    attrs = {
        "aliases": attr.string_dict(mandatory = True),
        "expected_alias": attr.string(mandatory = True),
        "expected_label": attr.string(mandatory = True),
    },
)

def _verify_absent_impl(ctx):
    if ctx.attr.unexpected in ctx.attr.items:
        fail("Did not expect %r in %r" % (ctx.attr.unexpected, ctx.attr.items))

    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(out, "ok\n")
    return [DefaultInfo(files = depset([out]))]

_verify_absent = rule(
    implementation = _verify_absent_impl,
    attrs = {
        "items": attr.string_list(mandatory = True),
        "unexpected": attr.string(mandatory = True),
    },
)

def _verify_present_impl(ctx):
    if ctx.attr.expected not in ctx.attr.items:
        fail("Expected %r in %r" % (ctx.attr.expected, ctx.attr.items))

    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(out, "ok\n")
    return [DefaultInfo(files = depset([out]))]

_verify_present = rule(
    implementation = _verify_present_impl,
    attrs = {
        "expected": attr.string(mandatory = True),
        "items": attr.string_list(mandatory = True),
    },
)

def verify_dep_absent(name, dep_data, unexpected):
    items = list(dep_data.get("deps", []))
    for values in dep_data.get("deps_by_platform", {}).values():
        items.extend(values)

    _verify_absent(
        name = name,
        items = sorted(items),
        unexpected = unexpected,
    )

def verify_dep_present(name, dep_data, expected):
    items = list(dep_data.get("deps", []))
    for values in dep_data.get("deps_by_platform", {}).values():
        items.extend(values)

    _verify_present(
        name = name,
        expected = expected,
        items = sorted(items),
    )

def verify_crate_feature_absent(name, dep_data, unexpected):
    items = list(dep_data.get("crate_features", []))
    for values in dep_data.get("crate_features_by_platform", {}).values():
        items.extend(values)

    _verify_absent(
        name = name,
        items = sorted(items),
        unexpected = unexpected,
    )
