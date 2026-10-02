#[test]
fn fips_crypto_and_wrapper() {
    aws_lc_fips_sys::init();
    unsafe {
        assert_eq!(aws_lc_fips_sys::FIPS_mode(), 1);
    }
    // ERR_GET_LIB calls the native Rust wrapper rather than a crypto symbol.
    assert_eq!(aws_lc_fips_sys::ERR_GET_LIB(0), 0);
    let digest = aws_lc_rs::digest::digest(&aws_lc_rs::digest::SHA256, b"rules_rs");
    assert_eq!(digest.as_ref().len(), 32);
    aws_lc_rs::try_fips_mode().unwrap();
}
