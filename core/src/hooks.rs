use std::fs;
use std::path::{Path, PathBuf};

use serde_json::{json, Value};

use crate::error::{Error, Result};
use crate::json::{pretty, read_object, write_atomic, Object};
use crate::system::shell_quote;

pub const SUBCOMMAND: &str = "limit-reached";
const EVENT: &str = "StopFailure";

pub struct Hooks {
    pub settings: PathBuf,
}

impl Hooks {
    pub fn new(settings: PathBuf) -> Hooks {
        Hooks { settings }
    }

    pub fn command(executable: &Path) -> String {
        format!(
            "{} {SUBCOMMAND}",
            shell_quote(&executable.to_string_lossy())
        )
    }

    pub fn is_ours(command: &str) -> bool {
        command.to_lowercase().contains("swapbot")
            && (command.ends_with(&format!(" {SUBCOMMAND}"))
                || command.ends_with(&format!(" --{SUBCOMMAND}")))
    }

    pub fn installed_command(&self) -> Option<String> {
        let settings = self.read().ok()?;
        settings
            .get("hooks")?
            .get(EVENT)?
            .as_array()?
            .iter()
            .filter_map(|entry| entry.get("hooks")?.as_array())
            .flatten()
            .filter_map(|hook| hook.get("command")?.as_str())
            .find(|command| Self::is_ours(command))
            .map(String::from)
    }

    pub fn install(&self, executable: &Path) -> Result<()> {
        let command = Self::command(executable);
        self.update(|entries| {
            entries.push(json!({
                "matcher": "rate_limit",
                "hooks": [{ "type": "command", "command": command, "timeout": 30 }],
            }))
        })
    }

    pub fn uninstall(&self) -> Result<()> {
        if self.installed_command().is_none() {
            return Ok(());
        }
        self.update(|_| {})
    }

    pub fn refresh(&self, executable: &Path) -> Result<bool> {
        match self.installed_command() {
            Some(installed) if installed != Self::command(executable) => {
                self.install(executable).map(|_| true)
            }
            _ => Ok(false),
        }
    }

    fn update(&self, change: impl FnOnce(&mut Vec<Value>)) -> Result<()> {
        let mut settings = self.read()?;
        let mut entries: Vec<Value> = settings
            .get("hooks")
            .and_then(|hooks| hooks.get(EVENT))
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .filter_map(Self::without_ours)
            .collect();
        change(&mut entries);

        let hooks = settings
            .entry("hooks")
            .or_insert_with(|| Value::Object(Object::new()));
        if !hooks.is_object() {
            *hooks = Value::Object(Object::new());
        }
        if let Some(hooks) = hooks.as_object_mut() {
            if entries.is_empty() {
                hooks.shift_remove(EVENT);
            } else {
                hooks.insert(EVENT.to_string(), Value::Array(entries));
            }
            if hooks.is_empty() {
                settings.shift_remove("hooks");
            }
        }

        if let Some(dir) = self.settings.parent() {
            fs::create_dir_all(dir)
                .map_err(|e| Error::Settings(format!("couldn't write it ({e})")))?;
        }
        let data =
            pretty(&settings).map_err(|e| Error::Settings(format!("couldn't write it ({e})")))?;
        write_atomic(&self.settings, &data, None)
            .map_err(|e| Error::Settings(format!("couldn't write it ({e})")))
    }

    fn without_ours(mut entry: Value) -> Option<Value> {
        let Some(commands) = entry.get("hooks").and_then(Value::as_array) else {
            return Some(entry);
        };
        let kept: Vec<Value> = commands
            .iter()
            .filter(|hook| {
                !hook
                    .get("command")
                    .and_then(Value::as_str)
                    .is_some_and(Self::is_ours)
            })
            .cloned()
            .collect();
        if kept.is_empty() {
            return None;
        }
        entry["hooks"] = Value::Array(kept);
        Some(entry)
    }

    pub(crate) fn read(&self) -> Result<Object> {
        if !self.settings.exists() {
            return Ok(Object::new());
        }
        read_object(&self.settings)
            .ok()
            .flatten()
            .ok_or_else(|| Error::Settings("it isn't valid JSON, so it was left alone".to_string()))
    }
}
