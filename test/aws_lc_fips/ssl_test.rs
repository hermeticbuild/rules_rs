#[test]
fn fips_ssl_context() {
    aws_lc_fips_sys::init();
    unsafe {
        assert_eq!(aws_lc_fips_sys::FIPS_mode(), 1);
        let context = aws_lc_fips_sys::SSL_CTX_new(aws_lc_fips_sys::TLS_method());
        assert!(!context.is_null());
        aws_lc_fips_sys::SSL_CTX_free(context);
    }
    assert_eq!(aws_lc_fips_sys::ERR_GET_LIB(0), 0);
    let digest = aws_lc_rs::digest::digest(&aws_lc_rs::digest::SHA256, b"rules_rs");
    assert_eq!(digest.as_ref().len(), 32);
    aws_lc_rs::try_fips_mode().unwrap();
}
