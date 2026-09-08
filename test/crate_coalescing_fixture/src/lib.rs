pub fn render(value: u64) -> String {
    let mut buffer = itoa::Buffer::new();
    buffer.format(value).to_owned()
}
