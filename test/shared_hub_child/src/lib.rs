//! A crate in a *separate* bzlmod module that emits a `log` record. It depends
//! on `@shared_hub//:log` — the hub declared by the owning module — via
//! `crate.use_hub`. If the hub is shared, this record reaches the logger the
//! owning module installed.
pub fn emit() {
    log::info!("hello from the consumer module");
}
