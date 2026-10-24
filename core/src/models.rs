use std::cmp::Ordering;

use chrono::{DateTime, Utc};
use serde::Serialize;
use serde_json::Value;

use crate::dates;
use crate::json::Object;
use crate::usage::Usage;

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AccountInfo {
    pub account_uuid: Option<String>,
    pub organization_uuid: Option<String>,
    pub email: Option<String>,
    pub organization_name: Option<String>,
    pub organization_label: Option<String>,
    pub display_name: Option<String>,
}

impl AccountInfo {
    pub fn from_json(value: Option<&Value>) -> Option<Self> {
        let object = value?.as_object()?;
        let text = |key: &str| object.get(key).and_then(Value::as_str).map(String::from);
        let account_uuid = text("accountUuid");
        let email = text("emailAddress");
        if account_uuid.is_none() && email.is_none() {
            return None;
        }
        let organization_name = text("organizationName");
        Some(AccountInfo {
            account_uuid,
            organization_uuid: text("organizationUuid"),
            email,
            organization_label: organization_name.as_deref().map(|name| {
                if name.ends_with("'s Organization") {
                    "Personal".to_string()
                } else {
                    name.to_string()
                }
            }),
            organization_name,
            display_name: text("displayName"),
        })
    }

    pub fn same_login(&self, other: &AccountInfo) -> bool {
        if let (Some(a), Some(b)) = (&self.account_uuid, &other.account_uuid) {
            return a == b && self.organization_uuid == other.organization_uuid;
        }
        self.email.is_some() && self.email == other.email
    }

    pub fn shares_prompt_cache(&self, other: &AccountInfo) -> bool {
        self.organization_uuid.is_some() && self.organization_uuid == other.organization_uuid
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenInfo {
    pub has_tokens: bool,
    pub subscription_type: Option<String>,
    #[serde(with = "dates::option")]
    pub access_expires: Option<DateTime<Utc>>,
    #[serde(with = "dates::option")]
    pub refresh_expires: Option<DateTime<Utc>>,
}

impl TokenInfo {
    pub fn from_oauth(oauth: &Object) -> Self {
        let non_empty = |key: &str| {
            oauth
                .get(key)
                .and_then(Value::as_str)
                .is_some_and(|s| !s.is_empty())
        };
        let date = |key: &str| {
            oauth
                .get(key)
                .and_then(Value::as_f64)
                .and_then(dates::from_millis)
        };
        TokenInfo {
            has_tokens: non_empty("accessToken") && non_empty("refreshToken"),
            subscription_type: oauth
                .get("subscriptionType")
                .and_then(Value::as_str)
                .map(String::from),
            access_expires: date("expiresAt"),
            refresh_expires: date("refreshTokenExpiresAt"),
        }
    }

    pub fn is_refresh_expired(&self, now: DateTime<Utc>) -> bool {
        self.refresh_expires.is_some_and(|expires| expires <= now)
    }

    pub fn is_usable(&self, now: DateTime<Utc>) -> bool {
        self.has_tokens && !self.is_refresh_expired(now)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Profile {
    pub name: String,
    pub account: Option<AccountInfo>,
    pub tokens: Option<TokenInfo>,
    pub usage: Option<Usage>,
}

pub fn find_active<'a>(profiles: &'a [Profile], current: &AccountInfo) -> Option<&'a Profile> {
    profiles
        .iter()
        .find(|p| p.account.as_ref().is_some_and(|a| a.same_login(current)))
}

pub fn natural_cmp(a: &str, b: &str) -> Ordering {
    let (mut x, mut y) = (a.chars().peekable(), b.chars().peekable());
    loop {
        match (x.peek().copied(), y.peek().copied()) {
            (None, None) => return a.cmp(b),
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(c), Some(d)) if c.is_ascii_digit() && d.is_ascii_digit() => {
                let take = |it: &mut std::iter::Peekable<std::str::Chars>| {
                    let mut digits = String::new();
                    while let Some(c) = it.peek().copied().filter(char::is_ascii_digit) {
                        digits.push(c);
                        it.next();
                    }
                    digits.trim_start_matches('0').to_string()
                };
                let (n, m) = (take(&mut x), take(&mut y));
                let order = n.len().cmp(&m.len()).then_with(|| n.cmp(&m));
                if order != Ordering::Equal {
                    return order;
                }
            }
            (Some(c), Some(d)) => {
                let order = c.to_lowercase().cmp(d.to_lowercase());
                if order != Ordering::Equal {
                    return order;
                }
                x.next();
                y.next();
            }
        }
    }
}

pub fn suggested_name(email: Option<&str>, exists: impl Fn(&str) -> bool) -> String {
    let base = email.and_then(|e| e.split('@').next()).unwrap_or("account");
    let cleaned: String = base
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || "._-".contains(c) {
                c
            } else {
                '-'
            }
        })
        .collect();
    let cleaned = cleaned.trim_start_matches(|c: char| !c.is_ascii_alphanumeric());
    let cleaned = if cleaned.is_empty() {
        "account"
    } else {
        cleaned
    };
    let mut name: String = cleaned.chars().take(40).collect();
    let mut n = 2;
    while exists(&name) {
        name = format!("{}-{n}", cleaned.chars().take(36).collect::<String>());
        n += 1;
    }
    name
}
