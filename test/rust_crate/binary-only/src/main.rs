mod helper;

fn main() {
    println!("{}", helper::message());
}

#[cfg(test)]
mod tests {
    #[test]
    fn binary_only_packages_can_have_modules() {
        assert_eq!(super::helper::message(), "binary-only");
    }
}
