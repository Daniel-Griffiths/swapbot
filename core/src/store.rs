use std::env;
use std::fs;
use std::path::PathBuf;
use std::sync::LazyLock;

use chrono::{DateTime, Utc};
use regex::Regex;
use serde_json::Value;

use crate::auto_switch::AutoSwitch;
use crate::credentials::{self, Credentials, Slot};
use crate::error::{Error, Result};
use crate::json::{compact, object_at, parse_object, pretty, write_atomic, Object};
use crate::models::{find_active, natural_cmp, AccountInfo, Profile, TokenInfo};
use crate::system;
use crate::usage::{CachedUsage, Usage, UsageLimit};

#[derive(Debug, Clone)]
pub struct Paths {
    pub service: String,
    pub profile_dir: PathBuf,
    pub claude_json: PathBuf,
    pub claude_settings: PathBuf,
    pub credentials_file: PathBuf,
}

impl Paths {
    pub fn live() -> Paths {
        let home = system::home();
        let path = |key: &str| {
            env::var_os(key)
                .filter(|v| !v.is_empty())
                .map(PathBuf::from)
        };
        Paths {
            service: env::var("SWAPBOT_SERVICE")
                .unwrap_or_else(|_| "Claude Code-credentials".to_string()),
            profile_dir: path("SWAPBOT_PROFILE_DIR")
                .unwrap_or_else(|| home.join(".claude/account-profiles")),
            claude_json: path("SWAPBOT_CLAUDE_JSON").unwrap_or_else(|| home.join(".claude.json")),
            claude_settings: path("SWAPBOT_CLAUDE_SETTINGS")
                .unwrap_or_else(|| home.join(".claude/settings.json")),
            credentials_file: path("SWAPBOT_CREDENTIALS_FILE")
                .unwrap_or_else(|| home.join(".claude/.credentials.json")),
        }
    }
}

static VALID_NAME: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$").unwrap());

pub struct Store {
    pub paths: Paths,
    pub(crate) credentials: Box<dyn Credentials>,
}

impl Store {
    pub fn new(paths: Paths, credentials: Box<dyn Credentials>) -> Store {
        Store { paths, credentials }
    }

    pub fn live() -> Store {
        let paths = Paths::live();
        let credentials = credentials::for_platform(&paths);
        Store::new(paths, credentials)
    }

    pub fn names(&self) -> Vec<String> {
        let Ok(entries) = fs::read_dir(&self.paths.profile_dir) else {
            return Vec::new();
        };
        let mut names: Vec<String> = entries
            .filter_map(|entry| {
                let file = entry.ok()?.file_name().into_string().ok()?;
                file.strip_suffix(".meta.json").map(String::from)
            })
            .collect();
        names.sort_by(|a, b| natural_cmp(a, b));
        names
    }

    pub fn profiles(&self, include_tokens: bool) -> Vec<Profile> {
        self.load(include_tokens, false).0
    }

    pub fn profiles_and_live_tokens(&self) -> (Vec<Profile>, Option<TokenInfo>) {
        self.load(true, true)
    }

    fn load(&self, include_tokens: bool, live: bool) -> (Vec<Profile>, Option<TokenInfo>) {
        let names = self.names();
        let mut slots: Vec<Slot> = if include_tokens {
            names.iter().map(|n| Slot::Saved(n.clone())).collect()
        } else {
            Vec::new()
        };
        if live {
            slots.push(Slot::Live);
        }
        let mut tokens: Vec<Option<TokenInfo>> = self
            .credentials
            .read_many(&slots)
            .into_iter()
            .map(|raw| {
                raw.as_deref()
                    .and_then(oauth_in)
                    .map(|oauth| TokenInfo::from_oauth(&oauth))
            })
            .collect();
        let live_tokens = if live { tokens.pop().flatten() } else { None };
        let profiles = names
            .into_iter()
            .enumerate()
            .map(|(i, name)| Profile {
                account: AccountInfo::from_json(
                    self.read_meta(&name)
                        .as_ref()
                        .and_then(|m| m.get("oauthAccount")),
                ),
                tokens: if include_tokens {
                    tokens[i].clone()
                } else {
                    None
                },
                usage: self.read_usage(&name),
                name,
            })
            .collect();
        (profiles, live_tokens)
    }

    pub fn current_account(&self) -> Option<AccountInfo> {
        AccountInfo::from_json(self.read_claude_json().ok()?.get("oauthAccount"))
    }

    pub fn current_tokens(&self) -> Option<TokenInfo> {
        self.live_oauth().map(|oauth| TokenInfo::from_oauth(&oauth))
    }

    pub fn active_in<'a>(&self, profiles: &'a [Profile]) -> Option<&'a Profile> {
        find_active(profiles, &self.current_account()?)
    }

    pub fn active_profile(&self) -> Option<Profile> {
        self.active_in(&self.profiles(false)).cloned()
    }

    pub fn fingerprint(&self) -> String {
        let account = self.current_account();
        let field = |f: fn(&AccountInfo) -> &Option<String>| {
            account
                .as_ref()
                .and_then(|a| f(a).clone())
                .unwrap_or_default()
        };
        let refresh = self
            .live_oauth()
            .and_then(|oauth| oauth.get("refreshToken").and_then(Value::as_str).map(fnv1a))
            .map(|hash| format!("{hash:016x}"))
            .unwrap_or_default();
        format!(
            "{}|{}|{}|{refresh}",
            field(|a| &a.account_uuid),
            field(|a| &a.organization_uuid),
            field(|a| &a.email)
        )
    }

    pub fn exists(&self, name: &str) -> bool {
        self.meta_path(name).exists()
    }

    pub fn validate(name: &str) -> Result<()> {
        if VALID_NAME.is_match(name) {
            Ok(())
        } else {
            Err(Error::InvalidName(name.to_string()))
        }
    }

    pub fn save(&self, name: &str, replacing: bool) -> Result<()> {
        Self::validate(name)?;
        if self.exists(name) && !replacing {
            return Err(Error::AlreadyExists(name.to_string()));
        }
        self.stash(name)
    }

    pub fn switch_to(&self, name: &str) -> Result<()> {
        if !self.exists(name) {
            return Err(Error::NoSuchProfile(name.to_string()));
        }
        let incoming = self
            .snapshot_oauth(name)
            .filter(|oauth| TokenInfo::from_oauth(oauth).has_tokens)
            .ok_or_else(|| Error::EmptySnapshot(name.to_string()))?;
        let all = self.profiles(false);
        if let Some(outgoing) = self.active_in(&all) {
            if outgoing.name == name {
                return Ok(());
            }
            let _ = self.stash(&outgoing.name);
        }

        let mut live = match self.credentials.read(&Slot::Live)? {
            Some(raw) => parse_object(&raw).ok_or_else(|| {
                Error::Credentials(
                    "The live Claude Code login isn't valid JSON, so it was left alone."
                        .to_string(),
                )
            })?,
            None => Object::new(),
        };
        live.insert("claudeAiOauth".to_string(), Value::Object(incoming));
        self.credentials.write(&Slot::Live, &compact(&live))?;

        if let Some(meta) = self.read_meta(name) {
            self.update_claude_json(|config| {
                for key in ["oauthAccount", "userID"] {
                    if let Some(value) = meta.get(key).filter(|v| !v.is_null()) {
                        config.insert(key.to_string(), value.clone());
                    }
                }
            })?;
        }
        Ok(())
    }

    pub fn remove(&self, name: &str) -> Result<()> {
        if !self.exists(name) {
            return Err(Error::NoSuchProfile(name.to_string()));
        }
        self.credentials.delete(&Slot::Saved(name.to_string()))?;
        fs::remove_file(self.meta_path(name))?;
        let _ = fs::remove_file(self.usage_path(name));
        AutoSwitch::new(self).update(|settings| settings.move_member(name, None));
        Ok(())
    }

    pub fn rename(&self, name: &str, new_name: &str) -> Result<()> {
        Self::validate(new_name)?;
        if !self.exists(name) {
            return Err(Error::NoSuchProfile(name.to_string()));
        }
        if new_name == name {
            return Ok(());
        }
        if self.exists(new_name) {
            return Err(Error::AlreadyExists(new_name.to_string()));
        }
        if let Some(snapshot) = self.credentials.read(&Slot::Saved(name.to_string()))? {
            self.credentials
                .write(&Slot::Saved(new_name.to_string()), &snapshot)?;
        }
        fs::rename(self.meta_path(name), self.meta_path(new_name))?;
        let _ = fs::rename(self.usage_path(name), self.usage_path(new_name));
        self.credentials.delete(&Slot::Saved(name.to_string()))?;
        AutoSwitch::new(self).update(|settings| settings.rename_member(name, new_name));
        Ok(())
    }

    pub fn record_usage(&self, name: &str, fetch: impl FnOnce() -> Option<Usage>) -> Option<Usage> {
        if !self.exists(name) {
            return None;
        }
        let usage = fetch()?;
        self.write_usage(&usage, name);
        Some(usage)
    }

    pub fn record_limit(&self, limit: &UsageLimit, name: &str, now: DateTime<Utc>) {
        if !self.exists(name) {
            return;
        }
        let usage = self
            .read_usage(name)
            .unwrap_or_else(|| Usage::new(Vec::new(), now));
        self.write_usage(&usage.marking(limit, now), name);
    }

    pub fn import_cached_usage(&self) -> Option<String> {
        let config = self.read_claude_json().ok()?;
        let cached = CachedUsage::from_json(config.get("cachedUsageUtilization"))?;
        let all = self.profiles(false);
        let mut matches: Vec<&Profile> = all
            .iter()
            .filter(|p| {
                p.account.as_ref().and_then(|a| a.account_uuid.as_deref())
                    == Some(cached.account_uuid.as_str())
            })
            .collect();
        if matches.len() > 1 {
            let active = AccountInfo::from_json(config.get("oauthAccount"))
                .and_then(|current| find_active(&all, &current));
            if let Some(active) = active.filter(|a| matches.iter().any(|m| m.name == a.name)) {
                matches = vec![active];
            }
        }
        let [profile] = matches.as_slice() else {
            return None;
        };
        if profile
            .usage
            .as_ref()
            .is_some_and(|usage| usage.recorded_at >= cached.usage.recorded_at)
        {
            return None;
        }
        self.write_usage(&cached.usage, &profile.name);
        Some(profile.name.clone())
    }

    fn stash(&self, name: &str) -> Result<()> {
        let live = self
            .credentials
            .read(&Slot::Live)?
            .as_deref()
            .and_then(parse_object)
            .ok_or(Error::NoLiveLogin)?;
        let oauth = object_at(&live, "claudeAiOauth")
            .filter(|oauth| TokenInfo::from_oauth(oauth).has_tokens)
            .ok_or(Error::EmptyLiveTokens)?;
        let mut snapshot = Object::new();
        snapshot.insert("claudeAiOauth".to_string(), Value::Object(oauth));
        self.credentials
            .write(&Slot::Saved(name.to_string()), &compact(&snapshot))?;

        let config = self.read_claude_json().unwrap_or_default();
        let mut meta = Object::new();
        for key in ["oauthAccount", "userID"] {
            meta.insert(
                key.to_string(),
                config.get(key).cloned().unwrap_or(Value::Null),
            );
        }
        fs::create_dir_all(&self.paths.profile_dir)?;
        write_atomic(&self.meta_path(name), &pretty(&meta)?, None)?;
        Ok(())
    }

    pub(crate) fn meta_path(&self, name: &str) -> PathBuf {
        self.paths.profile_dir.join(format!("{name}.meta.json"))
    }

    pub(crate) fn usage_path(&self, name: &str) -> PathBuf {
        self.paths.profile_dir.join(format!("{name}.usage.json"))
    }

    pub(crate) fn write_usage(&self, usage: &Usage, name: &str) {
        if let Ok(data) = pretty(usage) {
            let _ = write_atomic(&self.usage_path(name), &data, None);
        }
    }

    pub(crate) fn read_usage(&self, name: &str) -> Option<Usage> {
        serde_json::from_slice(&fs::read(self.usage_path(name)).ok()?).ok()
    }

    fn read_meta(&self, name: &str) -> Option<Object> {
        parse_object(&fs::read_to_string(self.meta_path(name)).ok()?)
    }

    pub(crate) fn snapshot_oauth(&self, name: &str) -> Option<Object> {
        let raw = self
            .credentials
            .read(&Slot::Saved(name.to_string()))
            .ok()??;
        oauth_in(&raw)
    }

    fn live_oauth(&self) -> Option<Object> {
        oauth_in(&self.credentials.read(&Slot::Live).ok()??)
    }

    pub(crate) fn read_claude_json(&self) -> Result<Object> {
        let text = fs::read_to_string(&self.paths.claude_json)
            .map_err(|e| Error::Config(format!("couldn't read it ({e})")))?;
        parse_object(&text).ok_or_else(|| Error::Config("it isn't a JSON object".to_string()))
    }

    pub(crate) fn update_claude_json(&self, change: impl FnOnce(&mut Object)) -> Result<()> {
        let mut config = self.read_claude_json()?;
        change(&mut config);
        let data =
            pretty(&config).map_err(|e| Error::Config(format!("couldn't write it ({e})")))?;
        write_atomic(&self.paths.claude_json, &data, None)
            .map_err(|e| Error::Config(format!("couldn't write it ({e})")))
    }
}

fn oauth_in(raw: &str) -> Option<Object> {
    object_at(&parse_object(raw)?, "claudeAiOauth")
}

fn fnv1a(text: &str) -> u64 {
    text.bytes().fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
        (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3)
    })
}
