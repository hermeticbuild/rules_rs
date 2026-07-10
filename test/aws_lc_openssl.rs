fn main() {
    let input = b"rules_rs";
    let aws_lc_digest = aws_lc_rs::digest::digest(&aws_lc_rs::digest::SHA256, input);
    let openssl_digest = openssl::hash::hash(openssl::hash::MessageDigest::sha256(), input)
        .expect("OpenSSL SHA-256 failed");
    assert_eq!(aws_lc_digest.as_ref(), openssl_digest.as_ref());

    unsafe {
        let context = aws_lc_sys::SSL_CTX_new(aws_lc_sys::TLS_method());
        assert!(!context.is_null());
        aws_lc_sys::SSL_CTX_free(context);
    }

    let _context = openssl::ssl::SslContextBuilder::new(openssl::ssl::SslMethod::tls())
        .expect("OpenSSL SSL context creation failed")
        .build();
}
