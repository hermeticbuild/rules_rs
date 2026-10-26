"""Check cargo_bin_name on a generated rust_binary."""

_CargoBinName = provider(fields = ["value"])

def _cargo_bin_name_impl(_target, ctx):
    return [_CargoBinName(value = ctx.rule.attr.cargo_bin_name)]

_cargo_bin_name = aspect(implementation = _cargo_bin_name_impl)

def _cargo_bin_name_test_impl(ctx):
    actual = ctx.attr.binary[_CargoBinName].value
    return [AnalysisTestResultInfo(
        success = actual == ctx.attr.expected,
        message = "Expected cargo_bin_name %r, got %r" % (ctx.attr.expected, actual),
    )]

cargo_bin_name_test = rule(
    implementation = _cargo_bin_name_test_impl,
    analysis_test = True,
    attrs = {
        "binary": attr.label(mandatory = True, aspects = [_cargo_bin_name]),
        "expected": attr.string(mandatory = True),
    },
)
