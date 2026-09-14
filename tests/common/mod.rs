use litebar_core::events::{classic_transition, event_spec};
use litebar_core::geometry::{section_mask, Rect};
use litebar_core::identity::Identity;
use std::fmt::Write;

fn rows(data: &str) -> impl Iterator<Item = Vec<&str>> {
    data.lines().skip(1).filter(|line| !line.is_empty()).map(|line| line.split('\t').collect())
}

fn rect(x: &str, width: &str) -> Rect {
    Rect { x: x.parse().unwrap(), y: 0.0, width: width.parse().unwrap(), height: 24.0 }
}

pub fn output() -> String {
    let mut output = String::new();
    for row in rows(include_str!("../fixtures/sections.tsv")) {
        assert_eq!(row.len(), 8);
        let hidden = rect(row[1], row[2]);
        let always = (row[3] != "-").then(|| rect(row[3], row[4]));
        let mask = section_mask(rect(row[5], row[6]), hidden, always);
        assert_eq!(mask, row[7].parse::<u32>().unwrap(), "{}", row[0]);
        writeln!(output, "section\t{}\t{}", row[0], mask).unwrap();
    }
    for row in rows(include_str!("../fixtures/identities.tsv")) {
        assert_eq!(row.len(), 5);
        let value = Identity::parse(row[0]);
        assert_eq!(value.namespace.as_str(), row[1]);
        assert_eq!(value.title, row[2]);
        assert_eq!(value.movable(), row[3] == "1");
        assert_eq!(value.hideable(), row[4] == "1");
        let encoded = value.encode();
        assert_eq!(value, Identity::parse(&encoded));
        writeln!(output, "identity\t{}\t{}\t{}\t{}", row[1], row[2], u8::from(value.movable()), u8::from(value.hideable())).unwrap();
    }
    for row in rows(include_str!("../fixtures/transitions.tsv")) {
        assert_eq!(row.len(), 5);
        let action = match row[3] { "show" => 0, "hide" => 1, "toggle" => 2, _ => panic!("invalid action") };
        let actual = classic_transition(row[1].parse().unwrap(), row[2].parse().unwrap(), action);
        assert_eq!(actual, row[4].parse::<u32>().unwrap(), "{}", row[0]);
        writeln!(output, "transition\t{}\t{}", row[0], actual).unwrap();
    }
    for row in rows(include_str!("../fixtures/events.tsv")) {
        assert_eq!(row.len(), 6);
        let spec = event_spec(row[1].parse().unwrap(), row[2].parse().unwrap());
        assert_eq!(spec.valid, 1);
        assert_eq!(spec.event_type, row[3].parse::<u32>().unwrap());
        assert_eq!(spec.flags, row[4].parse::<u64>().unwrap());
        let count = spec.click_count.max(0);
        assert_eq!(count, row[5].parse::<i32>().unwrap());
        writeln!(output, "event\t{}\t{}\t{}\t{}", row[0], spec.event_type, spec.flags, count).unwrap();
    }
    output
}
