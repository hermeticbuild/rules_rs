#[test]
fn two_hubs_expose_one_crate_identity() {
    let mut buffer = itoa::Buffer::new();
    assert_eq!(buffer.format(42), "42");
}
