#[cfg(not(feature = "with_itoa"))]
compile_error!("with_itoa should be enabled by default");

pub fn render(value: u64) -> String {
    let mut buffer = itoa::Buffer::new();
    buffer.format(value).to_owned()
}

#[cfg(test)]
mod tests {
    #[test]
    fn default_feature_links_optional_dependency() {
        assert_eq!(super::render(42), "42");
    }
}
