fn folded(value: &str) -> impl Iterator<Item = char> + '_ {
    value.chars().flat_map(char::to_lowercase)
}

pub fn score(query: &str, candidate: &str) -> Option<u32> {
    if query.len() > 1024 || candidate.len() > 16384 {
        return None;
    }
    let query = query.trim();
    if query.is_empty() {
        return Some(0);
    }
    if folded(query).eq(folded(candidate)) {
        return Some(0);
    }
    let mut needed = folded(query).peekable();
    let mut first = None;
    let mut previous = 0;
    let mut gaps = 0u32;
    for (index, ch) in folded(candidate).enumerate() {
        if needed.peek() == Some(&ch) {
            needed.next();
            if first.is_some() {
                gaps = gaps.saturating_add((index - previous - 1) as u32);
            } else {
                first = Some(index as u32);
            }
            previous = index;
            if needed.peek().is_none() {
                return Some(1 + first.unwrap_or(0) * 2 + gaps * 4);
            }
        }
    }
    None
}
