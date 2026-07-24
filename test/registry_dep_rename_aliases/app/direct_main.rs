fn main() {
    let mut buffer = itoa::Buffer::new();
    println!("direct hub alias says: {}", buffer.format(42));
}
