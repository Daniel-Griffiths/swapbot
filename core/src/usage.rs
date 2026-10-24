use std::path::PathBuf;
use std::sync::LazyLock;
use std::time::Duration;

use chrono::{DateTime, Datelike, Local, NaiveDate, TimeDelta, TimeZone, Utc};
use chrono_tz::Tz;
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::dates;
use crate::system;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageWindow {
    pub name: String,
    pub percent: f64,
    #[serde(
        default,
        with = "dates::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub resets_at: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resets_text: Option<String>,
}

impl UsageWindow {
    pub fn new(name: &str, percent: f64, resets_at: Option<DateTime<Utc>>) -> Self {
        UsageWindow {
            name: name.to_string(),
            percent,
            resets_at,
            resets_text: None,
        }
    }

    pub fn has_reset(&self, now: DateTime<Utc>) -> bool {
        self.resets_at.is_some_and(|resets| resets <= now)
    }

    fn is_full(&self, now: DateTime<Utc>) -> bool {
        !self.has_reset(now) && self.percent >= 100.0
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Usage {
    pub windows: Vec<UsageWindow>,
    #[serde(with = "dates")]
    pub recorded_at: DateTime<Utc>,
}

static USAGE_LINE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?m)^Current (session|week[^:]*):\s*(\d+(?:\.\d+)?)% used(?:\s*·\s*resets\s+(.+?))?\s*$",
    )
    .unwrap()
});
static TIME_ZONE_SUFFIX: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\s*\([^)]*\)\s*$").unwrap());
static RESET_TIME: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)^(?:([a-z]{3})[a-z]*\.?\s+(\d{1,2})(?:,\s*(\d{4}))?\s+at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)$")
        .unwrap()
});
static LIMIT: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?im)hit your (.+?) limit(?:\s*·\s*resets\s+(.+?))?\s*$").unwrap()
});

const MONTHS: [&str; 12] = [
    "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
];

impl Usage {
    pub fn new(windows: Vec<UsageWindow>, recorded_at: DateTime<Utc>) -> Self {
        Usage {
            windows,
            recorded_at,
        }
    }

    pub fn from_claude_output(text: &str, now: DateTime<Utc>) -> Option<Usage> {
        let windows: Vec<UsageWindow> = USAGE_LINE
            .captures_iter(text)
            .filter_map(|captures| {
                let percent: f64 = captures[2].parse().ok()?;
                let resets = captures.get(3).map(|m| m.as_str());
                Some(UsageWindow {
                    name: capitalized(&captures[1]),
                    percent,
                    resets_at: resets.and_then(|r| parse_reset(r, now)),
                    resets_text: resets.map(strip_time_zone),
                })
            })
            .collect();
        (!windows.is_empty()).then_some(Usage {
            windows,
            recorded_at: now,
        })
    }

    pub fn marking(&self, limit: &UsageLimit, now: DateTime<Utc>) -> Usage {
        let full = UsageWindow {
            name: limit.window.clone(),
            percent: 100.0,
            resets_at: Some(limit.resets_at),
            resets_text: limit.resets_text.clone(),
        };
        let mut windows = self.windows.clone();
        if let Some(existing) = windows.iter_mut().find(|w| w.name == limit.window) {
            *existing = full;
        } else if limit.window == "Session" {
            windows.insert(0, full);
        } else {
            windows.push(full);
        }
        Usage {
            windows,
            recorded_at: now,
        }
    }

    pub fn is_exhausted(&self, now: DateTime<Utc>) -> bool {
        self.windows.iter().any(|w| w.is_full(now))
    }

    pub fn available_at(&self, now: DateTime<Utc>) -> Option<DateTime<Utc>> {
        let full: Vec<&UsageWindow> = self.windows.iter().filter(|w| w.is_full(now)).collect();
        if full.is_empty() {
            return Some(now);
        }
        let resets: Vec<DateTime<Utc>> = full.iter().filter_map(|w| w.resets_at).collect();
        if resets.len() == full.len() {
            resets.into_iter().max()
        } else {
            None
        }
    }

    pub fn peak_percent(&self, now: DateTime<Utc>) -> f64 {
        self.windows
            .iter()
            .filter(|w| !w.has_reset(now))
            .map(|w| w.percent)
            .fold(0.0, f64::max)
    }
}

fn capitalized(text: &str) -> String {
    let mut chars = text.chars();
    chars
        .next()
        .map(|first| first.to_uppercase().chain(chars).collect())
        .unwrap_or_default()
}

pub fn strip_time_zone(text: &str) -> String {
    TIME_ZONE_SUFFIX.replace(text, "").into_owned()
}

pub fn parse_reset(text: &str, now: DateTime<Utc>) -> Option<DateTime<Utc>> {
    let zone = match (text.rfind('('), text.rfind(')')) {
        (Some(open), Some(close)) if open < close => text[open + 1..close].parse::<Tz>().ok(),
        _ => None,
    };
    let text = strip_time_zone(text);
    match zone {
        Some(zone) => resolve_reset(text.trim(), now, &zone),
        None => resolve_reset(text.trim(), now, &Local),
    }
}

fn resolve_reset<Z: TimeZone>(text: &str, now: DateTime<Utc>, zone: &Z) -> Option<DateTime<Utc>> {
    let captures = RESET_TIME.captures(text)?;
    let hour: u32 = captures[4].parse().ok()?;
    if !(1..=12).contains(&hour) {
        return None;
    }
    let minute: u32 = captures
        .get(5)
        .map_or(Some(0), |m| m.as_str().parse().ok())?;
    let hour = hour % 12
        + if captures[6].eq_ignore_ascii_case("pm") {
            12
        } else {
            0
        };
    let local_now = now.with_timezone(zone);
    let at = |date: NaiveDate| {
        zone.from_local_datetime(&date.and_hms_opt(hour, minute, 0)?)
            .earliest()
            .map(|d| d.with_timezone(&Utc))
    };

    if let Some(month) = captures.get(1) {
        let month = MONTHS
            .iter()
            .position(|m| m.eq_ignore_ascii_case(month.as_str()))? as u32
            + 1;
        let day: u32 = captures[2].parse().ok()?;
        let explicit_year = match captures.get(3) {
            Some(year) => Some(year.as_str().parse::<i32>().ok()?),
            None => None,
        };
        let year = explicit_year.unwrap_or(local_now.year());
        let date = at(NaiveDate::from_ymd_opt(year, month, day)?)?;
        if explicit_year.is_none() && date < now - TimeDelta::days(30) {
            return at(NaiveDate::from_ymd_opt(year + 1, month, day)?);
        }
        return Some(date);
    }

    let today = local_now.date_naive();
    let date = at(today)?;
    if date < now {
        return at(today.succ_opt()?);
    }
    Some(date)
}

#[derive(Debug, Clone, PartialEq)]
pub struct UsageLimit {
    pub window: String,
    pub resets_at: DateTime<Utc>,
    pub resets_text: Option<String>,
}

impl UsageLimit {
    pub fn from_message(message: &str, now: DateTime<Utc>) -> Option<UsageLimit> {
        let captures = LIMIT.captures(message)?;
        let kind = captures[1].to_lowercase();
        let resets = captures.get(2).map(|m| m.as_str());
        let window = if kind.contains("session") {
            "Session".to_string()
        } else if kind.contains("week") {
            "Week".to_string()
        } else {
            capitalized(&kind)
        };
        let fallback = if window == "Session" {
            TimeDelta::hours(5)
        } else {
            TimeDelta::days(7)
        };
        Some(UsageLimit {
            resets_at: resets
                .and_then(|r| parse_reset(r, now))
                .unwrap_or(now + fallback),
            resets_text: resets.map(strip_time_zone),
            window,
        })
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct CachedUsage {
    pub account_uuid: String,
    pub usage: Usage,
}

impl CachedUsage {
    const WINDOWS: [(&'static str, &'static str); 4] = [
        ("five_hour", "Session"),
        ("seven_day", "Week"),
        ("seven_day_opus", "Week (Opus)"),
        ("seven_day_sonnet", "Week (Sonnet)"),
    ];

    pub fn from_json(value: Option<&Value>) -> Option<CachedUsage> {
        let object = value?.as_object()?;
        let account_uuid = object.get("accountUuid")?.as_str()?.to_string();
        let fetched = object.get("fetchedAtMs")?.as_f64()?;
        let utilization = object.get("utilization")?.as_object()?;
        let windows: Vec<UsageWindow> = Self::WINDOWS
            .iter()
            .filter_map(|(key, name)| {
                let window = utilization.get(*key)?.as_object()?;
                let percent = window.get("utilization")?.as_f64()?;
                let resets_at = window
                    .get("resets_at")
                    .and_then(Value::as_str)
                    .and_then(Self::date);
                Some(UsageWindow::new(name, percent, resets_at))
            })
            .collect();
        if windows.is_empty() {
            return None;
        }
        let recorded_at = DateTime::from_timestamp((fetched / 1000.0).floor() as i64, 0)?;
        Some(CachedUsage {
            account_uuid,
            usage: Usage {
                windows,
                recorded_at,
            },
        })
    }

    fn date(text: &str) -> Option<DateTime<Utc>> {
        dates::parse(text).and_then(|date| DateTime::from_timestamp(date.timestamp(), 0))
    }
}

pub mod claude {
    use super::*;

    pub fn executable() -> Option<PathBuf> {
        if let Some(path) = std::env::var_os("SWAPBOT_CLAUDE").filter(|p| !p.is_empty()) {
            return Some(PathBuf::from(path));
        }
        let home = system::home();
        let candidates = [
            home.join(".local/bin/claude"),
            home.join(".claude/local/claude"),
            PathBuf::from("/opt/homebrew/bin/claude"),
            PathBuf::from("/usr/local/bin/claude"),
            PathBuf::from("/usr/bin/claude"),
        ];
        if let Some(found) = candidates.into_iter().find(|p| system::is_executable(p)) {
            return Some(found);
        }
        let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string());
        let output = system::run(
            shell,
            &["-ilc", "command -v claude"],
            Duration::from_secs(10),
            None,
        );
        let path = PathBuf::from(output.stdout.lines().last()?.trim());
        (path.is_absolute() && system::is_executable(&path)).then_some(path)
    }

    pub fn usage(timeout: Duration) -> Option<Usage> {
        let claude = executable()?;
        let output = system::run(
            claude,
            &["-p", "/usage"],
            timeout,
            Some(&std::env::temp_dir()),
        );
        if output.status != 0 {
            return None;
        }
        Usage::from_claude_output(&output.stdout, Utc::now())
    }
}
