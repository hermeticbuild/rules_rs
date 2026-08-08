pub fn double(x: i32) -> i32 {
    x * 2
}

/// Nothing exercises this, so every mutant of it survives.
pub fn triple(x: i32) -> i32 {
    x * 3
}

#[cfg(test)]
mod tests {
    use super::double;

    #[test]
    fn doubles() {
        assert_eq!(double(3), 6);
    }
}
