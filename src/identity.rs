#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum Namespace<'a> {
    Absent,
    Named(&'a str),
}

impl<'a> Namespace<'a> {
    pub fn as_str(self) -> &'a str {
        match self {
            Self::Absent => "<null>",
            Self::Named(value) => value,
        }
    }

    pub fn as_option(self) -> Option<&'a str> {
        match self {
            Self::Absent => None,
            Self::Named(value) => Some(value),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct Identity<'a> {
    pub namespace: Namespace<'a>,
    pub title: &'a str,
}

impl<'a> Identity<'a> {
    pub fn parse(value: &'a str) -> Self {
        let (namespace, title) = value.split_once(':').unwrap_or((value, ""));
        Self {
            namespace: Namespace::Named(namespace),
            title,
        }
    }

    pub fn encode(self) -> String {
        format!("{}:{}", self.namespace.as_str(), self.title)
    }

    pub fn movable(self) -> bool {
        !matches!(
            (self.namespace.as_str(), self.title),
            ("com.apple.controlcenter", "Clock" | "BentoBox")
                | ("com.apple.systemuiserver", "Siri")
        )
    }

    pub fn hideable(self) -> bool {
        !matches!(
            (self.namespace.as_str(), self.title),
            ("com.apple.controlcenter", "AudioVideoModule" | "FaceTime" | "MusicRecognition")
        )
    }

    pub fn special(self) -> bool {
        self.namespace == Namespace::Named("Special")
    }
}
