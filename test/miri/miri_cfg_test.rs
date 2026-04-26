#[cfg(miri)]
#[test]
fn runs_under_miri() {
    assert_eq!(2 + 2, 4);
}

#[cfg(not(miri))]
#[test]
fn would_fail_without_miri_cfg() {
    panic!("miri_test must pass cfg(miri)");
}
