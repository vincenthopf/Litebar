use litebar_core::identity::Identity;

#[test]
fn hosted_system_titles_keep_original_restrictions() {
    for title in ["Clock-0", "BentoBox-0", "BentoBox-19"] {
        assert!(!Identity::parse(&format!("com.apple.controlcenter:{title}")).movable());
    }
    for title in ["AudioVideoModule-0", "FaceTime-1", "MusicRecognition-12"] {
        assert!(!Identity::parse(&format!("com.apple.controlcenter:{title}")).hideable());
    }
    assert!(!Identity::parse("com.apple.systemuiserver:Siri-0").movable());
    assert!(Identity::parse("example:BentoBox-0").movable());
    assert!(Identity::parse("com.apple.controlcenter:BentoBox-custom").movable());
}
