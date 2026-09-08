use std::sync::atomic::{AtomicUsize, Ordering};

const ROOT_A_TARGET: &str = "crate_coalescing::root_a";
const ROOT_B_TARGET: &str = "crate_coalescing::root_b";
const BAR_TARGET: &str = "crate_coalescing::bar";
const BAZ_TARGET: &str = "crate_coalescing::baz";

struct ProbeLogger {
    root_a: AtomicUsize,
    root_b: AtomicUsize,
    bar: AtomicUsize,
    baz: AtomicUsize,
}

impl log::Log for ProbeLogger {
    fn enabled(&self, metadata: &log::Metadata<'_>) -> bool {
        matches!(
            metadata.target(),
            ROOT_A_TARGET | ROOT_B_TARGET | BAR_TARGET | BAZ_TARGET
        )
    }

    fn log(&self, record: &log::Record<'_>) {
        if !self.enabled(record.metadata()) {
            return;
        }

        let counter = match record.target() {
            ROOT_A_TARGET => &self.root_a,
            ROOT_B_TARGET => &self.root_b,
            BAR_TARGET => &self.bar,
            BAZ_TARGET => &self.baz,
            _ => return,
        };
        counter.fetch_add(1, Ordering::Relaxed);
    }

    fn flush(&self) {}
}

static PROBE_LOGGER: ProbeLogger = ProbeLogger {
    root_a: AtomicUsize::new(0),
    root_b: AtomicUsize::new(0),
    bar: AtomicUsize::new(0),
    baz: AtomicUsize::new(0),
};

pub fn install_log_probe() -> *const () {
    log::set_logger(&PROBE_LOGGER).expect("the singleton probe must own this test process's logger");
    log::set_max_level(log::LevelFilter::Info);
    probe_logger_data_ptr()
}

pub fn logger_data_ptr() -> *const () {
    log::logger() as *const dyn log::Log as *const ()
}

fn probe_logger_data_ptr() -> *const () {
    &PROBE_LOGGER as *const ProbeLogger as *const ()
}

pub fn emit_log_probe() {
    log::info!(target: BAR_TARGET, "bar dependency path reached the shared logger");
}

pub fn log_probe_counts() -> (usize, usize, usize, usize) {
    (
        PROBE_LOGGER.root_a.load(Ordering::Relaxed),
        PROBE_LOGGER.root_b.load(Ordering::Relaxed),
        PROBE_LOGGER.bar.load(Ordering::Relaxed),
        PROBE_LOGGER.baz.load(Ordering::Relaxed),
    )
}

#[derive(serde::Serialize)]
pub struct DerivedInBar {
    pub value: String,
}

pub fn request(path: &str) -> http::Request<String> {
    http::Request::builder()
        .uri(path)
        .body(local_helper::tag().to_owned())
        .expect("fixture request must be valid")
}

pub fn derived(value: &str) -> DerivedInBar {
    DerivedInBar {
        value: value.to_owned(),
    }
}
