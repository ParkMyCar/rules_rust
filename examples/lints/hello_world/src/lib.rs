pub fn add(left: u64, right: u64) -> u64 {
    left + right
}

fn foobar(x: usize) -> String {
    format!("hello world! {x}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn it_works() {
        let result = add(2, 2);
        assert_eq!(result, 4);
    }
}