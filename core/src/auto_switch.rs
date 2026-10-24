use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};
use std::fmt;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;

use chrono::{DateTime, TimeDelta, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::dates;
use crate::error::Result;
use crate::json::{pretty, write_atomic};
use crate::models::{natural_cmp, Profile};
use crate::store::Store;
use crate::usage::UsageLimit;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FallbackGroup {
    pub id: Uuid,
    pub name: String,
    #[serde(default)]
    pub members: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next: Option<Uuid>,
}

impl FallbackGroup {
    pub fn new(name: &str, members: &[&str]) -> FallbackGroup {
        FallbackGroup {
            id: Uuid::new_v4(),
            name: name.to_string(),
            members: members.iter().map(|m| m.to_string()).collect(),
            next: None,
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct AutoSwitchSettings {
    pub groups: Vec<FallbackGroup>,
}

impl AutoSwitchSettings {
    pub fn group_containing(&self, name: &str) -> Option<&FallbackGroup> {
        self.groups
            .iter()
            .find(|g| g.members.iter().any(|m| m == name))
    }

    pub fn group(&self, id: Option<Uuid>) -> Option<&FallbackGroup> {
        self.groups.iter().find(|g| Some(g.id) == id)
    }

    pub fn group_mut(&mut self, id: Uuid) -> Option<&mut FallbackGroup> {
        self.groups.iter_mut().find(|g| g.id == id)
    }

    pub fn find(&self, reference: &str) -> std::result::Result<Uuid, String> {
        if let Ok(id) = Uuid::parse_str(reference) {
            if self.group(Some(id)).is_some() {
                return Ok(id);
            }
        }
        let exact: Vec<&FallbackGroup> =
            self.groups.iter().filter(|g| g.name == reference).collect();
        let matches = if exact.is_empty() {
            self.groups
                .iter()
                .filter(|g| g.name.eq_ignore_ascii_case(reference))
                .collect()
        } else {
            exact
        };
        match matches.as_slice() {
            [group] => Ok(group.id),
            [] => Err(format!("No fallback group called “{reference}”.")),
            _ => Err(format!(
                "More than one group is called “{reference}”. Use its id instead."
            )),
        }
    }

    pub fn move_member(&mut self, name: &str, to: Option<Uuid>) {
        for group in &mut self.groups {
            group.members.retain(|m| m != name);
        }
        if let Some(group) = to.and_then(|id| self.group_mut(id)) {
            group.members.push(name.to_string());
        }
    }

    pub fn remove_group(&mut self, id: Uuid) {
        self.groups.retain(|g| g.id != id);
        for group in &mut self.groups {
            if group.next == Some(id) {
                group.next = None;
            }
        }
    }

    pub fn rename_member(&mut self, name: &str, new_name: &str) {
        for group in &mut self.groups {
            for member in &mut group.members {
                if member == name {
                    *member = new_name.to_string();
                }
            }
        }
    }

    pub fn defaults(profiles: &[Profile]) -> AutoSwitchSettings {
        let mut groups: Vec<FallbackGroup> = Vec::new();
        let mut by_organization: HashMap<String, usize> = HashMap::new();
        for profile in profiles {
            let account = profile.account.as_ref();
            let key = account
                .and_then(|a| a.organization_uuid.clone())
                .unwrap_or_else(|| profile.name.clone());
            if let Some(&i) = by_organization.get(&key) {
                groups[i].members.push(profile.name.clone());
            } else {
                by_organization.insert(key, groups.len());
                let name = account
                    .and_then(|a| a.organization_label.clone())
                    .unwrap_or_else(|| profile.name.clone());
                groups.push(FallbackGroup::new(&name, &[&profile.name]));
            }
        }
        AutoSwitchSettings { groups }
    }

    pub fn ordered(&self) -> Vec<&FallbackGroup> {
        let targeted: HashSet<Uuid> = self.groups.iter().filter_map(|g| g.next).collect();
        let mut order = Vec::new();
        let mut seen = HashSet::new();
        let starts = self
            .groups
            .iter()
            .filter(|g| !targeted.contains(&g.id))
            .chain(self.groups.iter());
        for start in starts {
            let mut group = Some(start);
            while let Some(current) = group.filter(|g| seen.insert(g.id)) {
                order.push(current);
                group = self.group(current.next);
            }
        }
        order
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Outcome {
    Switched {
        from: String,
        to: String,
    },
    Waiting {
        reason: String,
        until: DateTime<Utc>,
    },
    Ignored(String),
}

impl fmt::Display for Outcome {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Outcome::Switched { from, to } => write!(f, "switched from “{from}” to “{to}”"),
            Outcome::Waiting { reason, until } => {
                write!(f, "{reason}; trying again at {}", dates::format(until))
            }
            Outcome::Ignored(reason) => write!(f, "didn't switch: {reason}"),
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct State {
    #[serde(
        default,
        with = "dates::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub last_switch: Option<DateTime<Utc>>,
    #[serde(
        default,
        with = "dates::option",
        skip_serializing_if = "Option::is_none"
    )]
    pub retry_at: Option<DateTime<Utc>>,
}

pub struct AutoSwitch<'a> {
    pub store: &'a Store,
}

impl<'a> AutoSwitch<'a> {
    pub const DEBOUNCE: TimeDelta = TimeDelta::seconds(60);

    pub fn new(store: &'a Store) -> AutoSwitch<'a> {
        AutoSwitch { store }
    }

    pub fn has_settings(&self) -> bool {
        self.settings_path().exists()
    }

    pub fn settings(&self) -> AutoSwitchSettings {
        fs::read(self.settings_path())
            .ok()
            .and_then(|data| serde_json::from_slice(&data).ok())
            .unwrap_or_else(|| AutoSwitchSettings::defaults(&self.store.profiles(false)))
    }

    pub fn saved_settings(&self) -> Result<AutoSwitchSettings> {
        let settings = self.settings();
        if !self.has_settings() {
            self.save(&settings)?;
        }
        Ok(settings)
    }

    pub fn save(&self, settings: &AutoSwitchSettings) -> Result<()> {
        fs::create_dir_all(&self.store.paths.profile_dir)?;
        write_atomic(&self.settings_path(), &pretty(settings)?, None)?;
        Ok(())
    }

    pub fn update(&self, change: impl FnOnce(&mut AutoSwitchSettings)) {
        if !self.has_settings() {
            return;
        }
        let mut settings = self.settings();
        change(&mut settings);
        let _ = self.save(&settings);
    }

    fn chain<'p>(
        active: &Profile,
        profiles: &'p [Profile],
        settings: &AutoSwitchSettings,
        now: DateTime<Utc>,
    ) -> Vec<Vec<&'p Profile>> {
        let mut chain = Vec::new();
        let mut visited = HashSet::new();
        let mut group = settings.group_containing(&active.name);
        while let Some(current) = group.filter(|g| visited.insert(g.id)) {
            chain.push(
                profiles
                    .iter()
                    .filter(|p| {
                        p.name != active.name
                            && current.members.contains(&p.name)
                            && p.tokens.as_ref().is_some_and(|t| t.is_usable(now))
                    })
                    .collect(),
            );
            group = settings.group(current.next);
        }
        chain
    }

    pub fn fallback<'p>(
        active: &Profile,
        profiles: &'p [Profile],
        settings: &AutoSwitchSettings,
        now: DateTime<Utc>,
    ) -> Option<&'p Profile> {
        let peak = |p: &Profile| p.usage.as_ref().map_or(0.0, |u| u.peak_percent(now));
        Self::chain(active, profiles, settings, now)
            .into_iter()
            .find_map(|candidates| {
                candidates
                    .into_iter()
                    .filter(|p| !p.usage.as_ref().is_some_and(|u| u.is_exhausted(now)))
                    .min_by(|a, b| {
                        peak(a)
                            .partial_cmp(&peak(b))
                            .unwrap_or(Ordering::Equal)
                            .then_with(|| natural_cmp(&a.name, &b.name))
                    })
            })
    }

    pub fn next_availability(
        active: &Profile,
        profiles: &[Profile],
        settings: &AutoSwitchSettings,
        now: DateTime<Utc>,
    ) -> Option<DateTime<Utc>> {
        let earliest = Self::chain(active, profiles, settings, now)
            .into_iter()
            .flatten()
            .filter_map(|p| p.usage.as_ref().map_or(Some(now), |u| u.available_at(now)))
            .min()?;
        if active
            .usage
            .as_ref()
            .and_then(|u| u.available_at(now))
            .is_some_and(|own| own <= earliest)
        {
            return None;
        }
        Some(earliest)
    }

    pub fn handle_limit(&self, message: &str, now: DateTime<Utc>) -> Outcome {
        let Some(limit) = UsageLimit::from_message(message, now) else {
            return Outcome::Ignored(format!("not a usage limit: {message}"));
        };
        self.with_lock(|| {
            if let Some(last) = self.read_state().last_switch {
                let elapsed = now - last;
                if elapsed < Self::DEBOUNCE && now >= last {
                    return Outcome::Ignored(format!("switched {}s ago", elapsed.num_seconds()));
                }
            }
            let Some(active) = self.store.active_profile() else {
                return Outcome::Ignored("the current login isn't a saved account".to_string());
            };
            self.store.record_limit(&limit, &active.name, now);
            let reason = format!(
                "“{}” hit its {} limit",
                active.name,
                limit.window.to_lowercase()
            );
            self.switch_or_wait(&active.name, &reason, now)
        })
    }

    pub fn pending_retry(&self) -> Option<DateTime<Utc>> {
        self.read_state().retry_at
    }

    pub fn retry(&self, now: DateTime<Utc>) -> Outcome {
        self.with_lock(|| {
            let mut state = self.read_state();
            state.retry_at = None;
            self.write_state(&state);
            let Some(active) = self.store.active_profile() else {
                return Outcome::Ignored("the current login isn't a saved account".to_string());
            };
            if !active.usage.as_ref().is_some_and(|u| u.is_exhausted(now)) {
                return Outcome::Ignored(format!("“{}” has usage again, so it stays", active.name));
            }
            self.switch_or_wait(
                &active.name,
                &format!("“{}” is still used up", active.name),
                now,
            )
        })
    }

    fn switch_or_wait(&self, name: &str, reason: &str, now: DateTime<Utc>) -> Outcome {
        let settings = self.settings();
        if settings.group_containing(name).is_none() {
            return Outcome::Ignored(format!("{reason}; it isn't in a fallback group"));
        }
        let profiles = self.store.profiles(true);
        let Some(active) = profiles.iter().find(|p| p.name == name) else {
            return Outcome::Ignored(format!("{reason}; it's no longer saved"));
        };
        if let Some(target) = Self::fallback(active, &profiles, &settings, now) {
            if let Err(error) = self.store.switch_to(&target.name) {
                return Outcome::Ignored(format!("couldn't switch to “{}”: {error}", target.name));
            }
            self.write_state(&State {
                last_switch: Some(now),
                retry_at: None,
            });
            return Outcome::Switched {
                from: name.to_string(),
                to: target.name.clone(),
            };
        }
        let Some(available) = Self::next_availability(active, &profiles, &settings, now) else {
            return Outcome::Ignored(format!(
                "{reason}; nothing it can switch to resets before it does"
            ));
        };
        let until = available.max(now + TimeDelta::seconds(60));
        let mut state = self.read_state();
        state.retry_at = Some(until);
        self.write_state(&state);
        Outcome::Waiting {
            reason: format!("{reason} and everything it can switch to is used up"),
            until,
        }
    }

    pub fn log(&self, outcome: &Outcome, now: DateTime<Utc>) {
        self.log_line(&outcome.to_string(), now);
    }

    pub fn log_line(&self, text: &str, now: DateTime<Utc>) {
        let _ = fs::create_dir_all(&self.store.paths.profile_dir);
        if let Ok(mut file) = OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.log_path())
        {
            let _ = writeln!(file, "{} {text}", dates::format(&now));
        }
    }

    pub fn settings_path(&self) -> PathBuf {
        self.store.paths.profile_dir.join("auto-switch.json")
    }

    fn state_path(&self) -> PathBuf {
        self.store.paths.profile_dir.join("auto-switch.state.json")
    }

    fn lock_path(&self) -> PathBuf {
        self.store.paths.profile_dir.join("auto-switch.lock")
    }

    pub fn log_path(&self) -> PathBuf {
        self.store.paths.profile_dir.join("auto-switch.log")
    }

    pub(crate) fn read_state(&self) -> State {
        fs::read(self.state_path())
            .ok()
            .and_then(|data| serde_json::from_slice(&data).ok())
            .unwrap_or_default()
    }

    pub(crate) fn write_state(&self, state: &State) {
        if let Ok(data) = pretty(state) {
            let _ = write_atomic(&self.state_path(), &data, None);
        }
    }

    fn with_lock<T>(&self, body: impl FnOnce() -> T) -> T {
        let _ = fs::create_dir_all(&self.store.paths.profile_dir);
        let Ok(file) = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .mode(0o600)
            .open(self.lock_path())
        else {
            return body();
        };
        unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) };
        let result = body();
        unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_UN) };
        result
    }
}
