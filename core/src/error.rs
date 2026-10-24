use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    InvalidName(String),
    AlreadyExists(String),
    NoSuchProfile(String),
    NoLiveLogin,
    EmptyLiveTokens,
    EmptySnapshot(String),
    Credentials(String),
    Config(String),
    Settings(String),
    Io(String),
}

pub type Result<T> = std::result::Result<T, Error>;

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::InvalidName(n) => write!(
                f,
                "“{n}” isn't a valid name. Use letters, numbers, dots, dashes or underscores."
            ),
            Error::AlreadyExists(n) => write!(f, "There's already an account called “{n}”."),
            Error::NoSuchProfile(n) => write!(f, "No saved account called “{n}”."),
            Error::NoLiveLogin => write!(
                f,
                "Claude Code isn't logged in, so there's nothing to save."
            ),
            Error::EmptyLiveTokens => write!(
                f,
                "The current Claude Code login has empty tokens. Log in again before saving it."
            ),
            Error::EmptySnapshot(n) => write!(
                f,
                "The saved login for “{n}” has empty tokens. Log in to it again to refresh it."
            ),
            Error::Credentials(m) | Error::Io(m) => write!(f, "{m}"),
            Error::Config(m) => write!(f, "~/.claude.json: {m}"),
            Error::Settings(m) => write!(f, "~/.claude/settings.json: {m}"),
        }
    }
}

impl std::error::Error for Error {}

impl From<std::io::Error> for Error {
    fn from(error: std::io::Error) -> Self {
        Error::Io(error.to_string())
    }
}
