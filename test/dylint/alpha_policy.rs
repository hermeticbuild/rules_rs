#![feature(rustc_private)]

extern crate rustc_hir;

use rustc_hir::{Item, ItemKind};
use rustc_lint::{LateContext, LateLintPass, LintContext};

dylint_linting::declare_late_lint! {
    pub ALPHA_ONLY_API,
    Warn,
    "alpha-only API should not be used outside project alpha"
}

impl<'tcx> LateLintPass<'tcx> for AlphaOnlyApi {
    fn check_item(&mut self, cx: &LateContext<'tcx>, item: &'tcx Item<'tcx>) {
        if matches!(item.kind, ItemKind::Fn { .. })
            && cx.tcx.item_name(item.owner_id.def_id.to_def_id()).as_str() == "alpha_only"
        {
            cx.span_lint(ALPHA_ONLY_API, item.span, |diag| {
                diag.span_label(
                    item.span,
                    "alpha-only API should not be used outside project alpha",
                );
            });
        }
    }
}
