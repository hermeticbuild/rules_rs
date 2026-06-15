//! A crate in the hub-owning module that installs a process-global `log`
//! logger and counts the records it receives. Used by the cross-module
//! shared-hub test: if the consumer module shares this hub's `log`, the
//! consumer's log records land in this counter.
use std::sync::atomic::{AtomicUsize, Ordering};

use log::{LevelFilter, Log, Metadata, Record};

static COUNT: AtomicUsize = AtomicUsize::new(0);

struct CountingLogger;

impl Log for CountingLogger {
    fn enabled(&self, _: &Metadata) -> bool {
        true
    }
    fn log(&self, _: &Record) {
        COUNT.fetch_add(1, Ordering::SeqCst);
    }
    fn flush(&self) {}
}

static LOGGER: CountingLogger = CountingLogger;

/// Install the counting logger as `log`'s global logger.
pub fn install() {
    let _ = log::set_logger(&LOGGER);
    log::set_max_level(LevelFilter::Trace);
}

/// Number of records this logger has received.
pub fn count() -> usize {
    COUNT.load(Ordering::SeqCst)
}
