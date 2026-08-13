fn main() {
    println!("other-tool");
}

#[cfg(test)]
mod tests {
    #[test]
    fn additional_binary_only_targets_have_unit_tests() {
        assert_eq!(2 + 2, 4);
    }
}
