pub fn double(x: i32) -> i32 {
    x * 2
}

#[cfg(test)]
const COMPILE_DATA: &[u8] = include_bytes!("compile_data.bin");

#[cfg(test)]
mod tests {
    use super::{COMPILE_DATA, double};

    #[test]
    fn doubles() {
        assert_eq!(COMPILE_DATA, [0xff]);
        assert!(std::env::args().any(|arg| arg == "--nocapture"));
        assert_eq!(std::env::var("MUTANTS_TEST_ENV").as_deref(), Ok("present"));
        assert_eq!(
            std::fs::read_to_string("mutants/runtime_data.txt").unwrap(),
            "runtime data\n"
        );
        assert_eq!(double(0), 0);
        assert_eq!(double(3), 6);
        assert_eq!(double(-4), -8);
    }
}
