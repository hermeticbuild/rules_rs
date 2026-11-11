#[test]
fn profiler_starts_stopped() {
    // With manual lifetime, querying the profiler is safe before startup.
    assert_eq!(unsafe { tracy_client_sys::___tracy_profiler_started() }, 0);
}
