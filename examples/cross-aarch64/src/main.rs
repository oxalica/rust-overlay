#[test]
fn test_openssl_version() {
    openssl::init();
    assert!(openssl::version::version().starts_with("OpenSSL "));
}

fn main() {}
