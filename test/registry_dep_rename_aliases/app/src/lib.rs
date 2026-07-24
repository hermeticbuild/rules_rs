pub fn format_42() -> String {
    let mut buffer = my_itoa::Buffer::new();
    buffer.format(42).to_owned()
}

#[cfg(test)]
mod tests {
    #[test]
    fn renamed_dep_is_linked() {
        assert_eq!(super::format_42(), "42");
    }
}
