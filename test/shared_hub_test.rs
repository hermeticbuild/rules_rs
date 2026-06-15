//! Cross-module shared-hub test.
//!
//! The owning module (this test root) declares the `@shared_hub` hub and the
//! `shared_hub_logger` crate; a *separate* bzlmod module (`shared_hub_child`)
//! consumes that hub via `crate.use_hub` and emits a `log` record. If the hub
//! is shared, both modules link the same `log` rlib (one global logger
//! `static`), so the child's record reaches the logger this crate installs.
//!
//! Before the `use_hub` feature, the child could only declare its own hub,
//! producing a second `log` rlib with its own (uninitialized) logger — the
//! record would be lost and `count()` would stay 0.

#[test]
fn child_log_reaches_owning_modules_logger() {
    shared_hub_logger::install();
    assert_eq!(shared_hub_logger::count(), 0, "no records expected yet");

    shared_hub_child::emit();

    assert_eq!(
        shared_hub_logger::count(),
        1,
        "the consumer module's log record did not reach the owning module's \
         logger — the `@shared_hub` hub is not shared (two `log` statics)",
    );
}
