pub fn double(x: i32) -> i32 {
    x * 2
}

#[cfg(test)]
mod tests {
    use super::double;

    #[test]
    fn doubles() {
        assert_eq!(double(0), 0);
        assert_eq!(double(3), 6);
        assert_eq!(double(-4), -8);
    }
}
