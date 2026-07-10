#[test]
fn aws_lc_sys() {
    aws_lc_sys::init();

    let digest = aws_lc_rs::digest::digest(&aws_lc_rs::digest::SHA256, b"rules_rs");
    assert_eq!(digest.as_ref().len(), 32);

    unsafe {
        assert_eq!(aws_lc_sys::FIPS_version(), 0);

        let context = aws_lc_sys::SSL_CTX_new(aws_lc_sys::TLS_method());
        assert!(!context.is_null());
        aws_lc_sys::SSL_CTX_free(context);
    }
}
