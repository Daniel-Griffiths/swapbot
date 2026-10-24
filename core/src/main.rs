use std::env;
use std::fs;
use std::io::{self, Read};
use std::path::PathBuf;
use std::process::{Command as Process, ExitCode};
use std::time::Duration;

use chrono::{DateTime, Local, Utc};
use clap::{Parser, Subcommand};
use serde::Serialize;
use serde_json::Value;

use swapbot::auto_switch::{AutoSwitch, AutoSwitchSettings, FallbackGroup, Outcome};
use swapbot::dates;
use swapbot::hooks::Hooks;
use swapbot::models::{find_active, suggested_name, AccountInfo, Profile, TokenInfo};
use swapbot::processes;
use swapbot::store::Store;
use swapbot::usage::{claude, Usage};

#[derive(Parser)]
#[command(
    name = "swapbot",
    version,
    about = "Switch Claude Code between saved Claude accounts"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    #[command(about = "List saved accounts and their last recorded usage")]
    List {
        #[arg(long)]
        json: bool,
    },
    #[command(about = "Show the current login and every saved account")]
    Status {
        #[arg(long)]
        json: bool,
        #[arg(
            long,
            help = "Include each account's login expiry (reads every saved login)"
        )]
        tokens: bool,
    },
    #[command(about = "Switch Claude Code to a saved account")]
    Switch {
        name: String,
        #[command(flatten)]
        sessions: SessionFlags,
        #[arg(
            long,
            help = "Don't run `claude -p /usage` to record the outgoing account's usage"
        )]
        skip_usage: bool,
    },
    #[command(about = "Save the current Claude Code login as an account")]
    Save {
        name: String,
        #[arg(long, help = "Overwrite an account with the same name")]
        replace: bool,
    },
    #[command(about = "Run `claude auth login`, then save the new login")]
    Login {
        #[arg(help = "Account to log in to again, or the name for a new one")]
        name: Option<String>,
        #[command(flatten)]
        sessions: SessionFlags,
        #[arg(
            long,
            help = "Don't run `claude -p /usage` to record the outgoing account's usage"
        )]
        skip_usage: bool,
    },
    #[command(about = "Rename a saved account")]
    Rename { name: String, new_name: String },
    #[command(about = "Remove a saved account")]
    Remove { name: String },
    #[command(about = "Record the current account's usage with `claude -p /usage`")]
    RecordUsage,
    #[command(about = "List running Claude Code sessions")]
    Sessions {
        #[arg(long)]
        json: bool,
    },
    #[command(about = "Quit every running Claude Code session")]
    QuitSessions,
    #[command(about = "Show or change switching accounts automatically at usage limits")]
    AutoSwitch {
        #[arg(long)]
        json: bool,
        #[command(subcommand)]
        action: Option<AutoSwitchAction>,
    },
    #[command(about = "Arrange accounts in Auto-Switch fallback groups")]
    Group {
        #[command(subcommand)]
        action: GroupAction,
    },
    #[command(hide = true)]
    LimitReached,
    #[command(hide = true)]
    Fingerprint,
}

#[derive(clap::Args)]
struct SessionFlags {
    #[arg(
        long,
        conflicts_with = "ignore_sessions",
        help = "Quit running Claude Code sessions first"
    )]
    quit_sessions: bool,
    #[arg(long, help = "Leave running Claude Code sessions alone")]
    ignore_sessions: bool,
}

#[derive(Subcommand)]
enum AutoSwitchAction {
    #[command(about = "Add the Claude Code hook that switches accounts at usage limits")]
    On,
    #[command(about = "Remove the hook")]
    Off,
    #[command(about = "Switch now if the current account is still used up")]
    Retry,
    #[command(hide = true)]
    RefreshHook,
}

#[derive(Subcommand)]
enum GroupAction {
    #[command(about = "Add an empty group")]
    Add { name: String },
    #[command(about = "Delete a group; its accounts never switch")]
    Remove { group: String },
    #[command(about = "Rename a group")]
    Rename { group: String, name: String },
    #[command(about = "Move an account into a group, or to `none` so it never switches")]
    Move { account: String, group: String },
    #[command(about = "Set the group to try when every account in a group is used up, or `none`")]
    Next { group: String, next: String },
}

type CliResult = Result<(), String>;

fn main() -> ExitCode {
    let cli = Cli::parse();
    let store = Store::live();
    match run(cli.command, &store) {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("{message}");
            ExitCode::FAILURE
        }
    }
}

fn run(command: Command, store: &Store) -> CliResult {
    match command {
        Command::List { json } => list(store, json),
        Command::Status { json, tokens } => status(store, json, tokens),
        Command::Switch {
            name,
            sessions,
            skip_usage,
        } => switch(store, &name, &sessions, skip_usage),
        Command::Save { name, replace } => {
            store.save(&name, replace).map_err(|e| e.to_string())?;
            platform::notify_changed();
            println!("Saved the current login as “{name}”.");
            Ok(())
        }
        Command::Login {
            name,
            sessions,
            skip_usage,
        } => login(store, name, &sessions, skip_usage),
        Command::Rename { name, new_name } => {
            store.rename(&name, &new_name).map_err(|e| e.to_string())?;
            platform::notify_changed();
            println!("Renamed “{name}” to “{new_name}”.");
            Ok(())
        }
        Command::Remove { name } => {
            store.remove(&name).map_err(|e| e.to_string())?;
            platform::notify_changed();
            println!("Removed “{name}”.");
            Ok(())
        }
        Command::RecordUsage => record_usage(store),
        Command::Sessions { json } => {
            let pids = processes::claude_sessions();
            if json {
                print_json(&pids)
            } else {
                pids.iter().for_each(|pid| println!("{pid}"));
                Ok(())
            }
        }
        Command::QuitSessions => quit_sessions(&processes::claude_sessions()),
        Command::AutoSwitch { json, action } => auto_switch(store, json, action),
        Command::Group { action } => group(store, action),
        Command::LimitReached => {
            limit_reached(store);
            Ok(())
        }
        Command::Fingerprint => {
            println!("{}", store.fingerprint());
            Ok(())
        }
    }
}

fn print_json<T: Serialize + ?Sized>(value: &T) -> CliResult {
    let text = serde_json::to_string_pretty(value).map_err(|e| e.to_string())?;
    println!("{text}");
    Ok(())
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Status {
    current: Option<AccountInfo>,
    active: Option<String>,
    suggested_name: Option<String>,
    live_tokens: Option<TokenInfo>,
    #[serde(with = "dates::option")]
    pending_retry: Option<DateTime<Utc>>,
    accounts: Vec<Profile>,
}

fn load_status(store: &Store, tokens: bool) -> Status {
    store.import_cached_usage();
    let (accounts, live_tokens) = if tokens {
        store.profiles_and_live_tokens()
    } else {
        (store.profiles(false), None)
    };
    let current = store.current_account();
    let active = current
        .as_ref()
        .and_then(|c| find_active(&accounts, c))
        .map(|p| p.name.clone());
    let suggested = current.as_ref().filter(|_| active.is_none()).map(|c| {
        suggested_name(c.email.as_deref(), |name| {
            accounts.iter().any(|p| p.name == name)
        })
    });
    Status {
        pending_retry: AutoSwitch::new(store).pending_retry(),
        current,
        active,
        suggested_name: suggested,
        live_tokens,
        accounts,
    }
}

fn list(store: &Store, json: bool) -> CliResult {
    let status = load_status(store, false);
    if json {
        return print_json(&status.accounts);
    }
    if status.accounts.is_empty() {
        println!("No saved accounts. Save the current login with `swapbot save <name>`.");
    }
    let now = Utc::now();
    for profile in &status.accounts {
        let mark = if status.active.as_deref() == Some(&profile.name) {
            "*"
        } else {
            " "
        };
        let email = profile
            .account
            .as_ref()
            .and_then(|a| a.email.as_deref())
            .unwrap_or("?");
        let usage = profile
            .usage
            .as_ref()
            .map_or("no usage recorded".to_string(), |u| short_usage(u, now));
        println!("{mark} {}  {email}  {usage}", profile.name);
    }
    Ok(())
}

fn short_usage(usage: &Usage, now: DateTime<Utc>) -> String {
    usage
        .windows
        .iter()
        .map(|w| {
            if w.has_reset(now) {
                format!("{} has reset", w.name)
            } else {
                format!("{} {}%", w.name, w.percent.round())
            }
        })
        .collect::<Vec<_>>()
        .join(", ")
}

fn status(store: &Store, json: bool, tokens: bool) -> CliResult {
    let status = load_status(store, tokens || !json);
    if json {
        return print_json(&status);
    }
    let now = Utc::now();
    match (&status.current, &status.active) {
        (None, _) => println!("Claude Code is signed out."),
        (Some(current), Some(active)) => {
            println!("Signed in as {} (“{active}”).", email(Some(current)))
        }
        (Some(current), None) => println!("Signed in as {} (not saved).", email(Some(current))),
    }
    if !status.accounts.is_empty() {
        println!();
    }
    for profile in &status.accounts {
        let is_active = status.active.as_deref() == Some(&profile.name);
        let tokens = if is_active {
            status.live_tokens.as_ref()
        } else {
            profile.tokens.as_ref()
        };
        let mut details = vec![email(profile.account.as_ref())];
        if let Some(plan) = tokens
            .and_then(|t| t.subscription_type.as_deref())
            .filter(|p| !p.is_empty())
        {
            details.push(capitalize(plan));
        }
        if let Some(warning) = login_warning(tokens, now) {
            details.push(warning);
        }
        println!(
            "{} {}  {}",
            if is_active { "*" } else { " " },
            profile.name,
            details.join(" · ")
        );
        if let Some(usage) = &profile.usage {
            for window in &usage.windows {
                println!("    {}", describe_window(window, now));
            }
        }
    }
    if let Some(retry) = status.pending_retry {
        println!("\nAuto-Switch tries again {}.", describe_time(retry, now));
    }
    Ok(())
}

fn email(account: Option<&AccountInfo>) -> String {
    account
        .and_then(|a| a.email.clone())
        .unwrap_or_else(|| "unknown account".to_string())
}

fn capitalize(text: &str) -> String {
    let mut chars = text.chars();
    chars
        .next()
        .map(|c| c.to_uppercase().chain(chars).collect())
        .unwrap_or_default()
}

fn login_warning(tokens: Option<&TokenInfo>, now: DateTime<Utc>) -> Option<String> {
    let tokens = tokens?;
    if !tokens.has_tokens {
        return Some("needs logging in again".to_string());
    }
    if tokens.is_refresh_expired(now) {
        return Some("login expired".to_string());
    }
    let days = (tokens.refresh_expires? - now).num_days();
    match days {
        0 => Some("login expires in under a day".to_string()),
        1 => Some("login expires in 1 day".to_string()),
        2..=6 => Some(format!("login expires in {days} days")),
        _ => None,
    }
}

fn describe_window(window: &swapbot::usage::UsageWindow, now: DateTime<Utc>) -> String {
    if window.has_reset(now) {
        return format!("{} has reset", window.name);
    }
    let percent = format!("{} {}%", window.name, window.percent.round());
    match (window.resets_at, &window.resets_text) {
        (Some(at), _) => format!("{percent} · resets {}", describe_time(at, now)),
        (None, Some(text)) => format!("{percent} · resets {text}"),
        _ => percent,
    }
}

fn describe_time(date: DateTime<Utc>, now: DateTime<Utc>) -> String {
    let minutes = (date - now).num_minutes();
    if minutes < 60 {
        format!("in {}m", minutes.max(1))
    } else if minutes < 24 * 60 {
        format!("in {}h {}m", minutes / 60, minutes % 60)
    } else {
        date.with_timezone(&Local).format("%a %-H:%M").to_string()
    }
}

fn settle_sessions(flags: &SessionFlags, what: &str) -> CliResult {
    let pids = processes::claude_sessions();
    if pids.is_empty() || flags.ignore_sessions {
        return Ok(());
    }
    if !flags.quit_sessions {
        let (count, verb, them) = if pids.len() == 1 {
            ("1 Claude Code session".to_string(), "is", "it")
        } else {
            (
                format!("{} Claude Code sessions", pids.len()),
                "are",
                "them",
            )
        };
        return Err(format!(
            "{count} {verb} running. Sessions left running carry on under the new account and resend their whole conversation uncached.\nPass --quit-sessions to quit {them} before {what}, or --ignore-sessions to leave {them} running."
        ));
    }
    quit_sessions(&pids)
}

fn quit_sessions(pids: &[i32]) -> CliResult {
    let survivors = processes::terminate(pids, Duration::from_secs(5));
    if survivors.is_empty() {
        return Ok(());
    }
    let list = survivors
        .iter()
        .map(i32::to_string)
        .collect::<Vec<_>>()
        .join(", ");
    Err(format!(
        "{} Claude Code process{} (PID {list}) {} still running, so nothing was changed.",
        survivors.len(),
        if survivors.len() == 1 { "" } else { "es" },
        if survivors.len() == 1 { "is" } else { "are" }
    ))
}

fn record_outgoing(store: &Store, name: &str) {
    store.record_usage(name, || claude::usage(Duration::from_secs(30)));
}

fn switch(store: &Store, name: &str, sessions: &SessionFlags, skip_usage: bool) -> CliResult {
    let profiles = store.profiles(true);
    let Some(profile) = profiles.iter().find(|p| p.name == name) else {
        return Err(format!("No saved account called “{name}”."));
    };
    let current = store.current_account();
    let outgoing = current
        .as_ref()
        .and_then(|c| find_active(&profiles, c))
        .map(|p| p.name.clone());
    if outgoing.as_deref() == Some(name) {
        println!("Already using “{name}”.");
        return Ok(());
    }
    if !profile
        .tokens
        .as_ref()
        .is_some_and(|t| t.is_usable(Utc::now()))
    {
        return Err(format!("The saved login for “{name}” has expired. Log in to it again with `swapbot login {name}`."));
    }
    let same_team = match (&current, &profile.account) {
        (Some(current), Some(account)) => account.shares_prompt_cache(current),
        _ => false,
    };
    if !same_team {
        settle_sessions(sessions, &format!("switching to “{name}”"))?;
    }
    if let Some(outgoing) = outgoing.filter(|_| !skip_usage) {
        record_outgoing(store, &outgoing);
    }
    store.switch_to(name).map_err(|e| e.to_string())?;
    platform::notify_changed();
    println!(
        "Switched to “{name}” ({}).",
        email(profile.account.as_ref())
    );
    Ok(())
}

fn login(
    store: &Store,
    name: Option<String>,
    sessions: &SessionFlags,
    skip_usage: bool,
) -> CliResult {
    if let Some(name) = &name {
        Store::validate(name).map_err(|e| e.to_string())?;
    }
    let profiles = store.profiles(false);
    let relogin_email = name
        .as_ref()
        .and_then(|n| profiles.iter().find(|p| &p.name == n))
        .and_then(|p| p.account.as_ref()?.email.clone());
    settle_sessions(sessions, "logging in")?;
    if let Some(active) = store.active_in(&profiles) {
        if !skip_usage {
            record_outgoing(store, &active.name);
        }
        store.save(&active.name, true).map_err(|e| e.to_string())?;
    }

    let claude = claude::executable().ok_or("Couldn't find the claude command.")?;
    let mut process = Process::new(claude);
    process.args(["auth", "login"]);
    if let Some(email) = &relogin_email {
        process.args(["--email", email]);
    }
    let finished = process
        .status()
        .map_err(|e| format!("Couldn't run claude auth login: {e}"))?;
    if !finished.success() {
        return Err("claude auth login didn't finish, so nothing was saved.".to_string());
    }

    let current = store
        .current_account()
        .ok_or("Claude Code still isn't signed in.")?;
    let signed_in = email(Some(&current));
    let profiles = store.profiles(false);
    if let Some(found) = find_active(&profiles, &current) {
        store.save(&found.name, true).map_err(|e| e.to_string())?;
        match name {
            Some(wanted) if wanted != found.name => println!(
                "You signed in as {signed_in}, which is saved as “{}”, not “{wanted}”. Updated “{}”.",
                found.name, found.name
            ),
            _ => println!("“{}” is ready: signed in as {signed_in}.", found.name),
        }
    } else {
        let new_name =
            name.unwrap_or_else(|| suggested_name(current.email.as_deref(), |n| store.exists(n)));
        store.save(&new_name, false).map_err(|e| e.to_string())?;
        println!("Saved {signed_in} as “{new_name}”.");
    }
    platform::notify_changed();
    Ok(())
}

fn record_usage(store: &Store) -> CliResult {
    let Some(active) = store.active_profile() else {
        return Ok(());
    };
    match store.record_usage(&active.name, || claude::usage(Duration::from_secs(30))) {
        Some(usage) => println!("{}: {}", active.name, short_usage(&usage, Utc::now())),
        None => println!("Couldn't read the usage of “{}”.", active.name),
    }
    Ok(())
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct AutoSwitchStatus {
    enabled: bool,
    hook_command: Option<String>,
    #[serde(with = "dates::option")]
    pending_retry: Option<DateTime<Utc>>,
    settings: AutoSwitchSettings,
    accounts: Vec<Profile>,
}

fn executable() -> Result<PathBuf, String> {
    env::current_exe()
        .and_then(fs::canonicalize)
        .map_err(|e| format!("Couldn't find the swapbot executable: {e}"))
}

fn auto_switch(store: &Store, json: bool, action: Option<AutoSwitchAction>) -> CliResult {
    let auto = AutoSwitch::new(store);
    let hooks = Hooks::new(store.paths.claude_settings.clone());
    match action {
        Some(AutoSwitchAction::On) => {
            auto.saved_settings().map_err(|e| e.to_string())?;
            hooks.install(&executable()?).map_err(|e| e.to_string())?;
        }
        Some(AutoSwitchAction::Off) => hooks.uninstall().map_err(|e| e.to_string())?,
        Some(AutoSwitchAction::Retry) => {
            let now = Utc::now();
            let outcome = auto.retry(now);
            auto.log(&outcome, now);
            after_auto_switch(&auto);
            println!("{outcome}");
            return Ok(());
        }
        Some(AutoSwitchAction::RefreshHook) => {
            hooks.refresh(&executable()?).map_err(|e| e.to_string())?;
            return Ok(());
        }
        None => {}
    }
    show_auto_switch(store, json)
}

fn show_auto_switch(store: &Store, json: bool) -> CliResult {
    let auto = AutoSwitch::new(store);
    let settings = auto.saved_settings().map_err(|e| e.to_string())?;
    let hook_command = Hooks::new(store.paths.claude_settings.clone()).installed_command();
    let accounts = store.profiles(false);
    if json {
        return print_json(&AutoSwitchStatus {
            enabled: hook_command.is_some(),
            hook_command,
            pending_retry: auto.pending_retry(),
            settings,
            accounts,
        });
    }

    match &hook_command {
        Some(command) => println!(
            "Auto-Switch is on. Claude Code runs {command} when a turn stops at a usage limit."
        ),
        None => println!("Auto-Switch is off. Turn it on with `swapbot auto-switch on`."),
    }
    if let Some(retry) = auto.pending_retry() {
        println!(
            "Every fallback is used up, so it tries again {}.",
            describe_time(retry, Utc::now())
        );
    }
    println!();
    for group in settings.ordered() {
        let members = if group.members.is_empty() {
            "(empty)".to_string()
        } else {
            group.members.join(", ")
        };
        let next = settings
            .group(group.next)
            .map(|n| format!("  →  then {}", n.name))
            .unwrap_or_default();
        println!("{}: {members}{next}", group.name);
    }
    let never: Vec<&str> = accounts
        .iter()
        .map(|p| p.name.as_str())
        .filter(|n| settings.group_containing(n).is_none())
        .collect();
    if !never.is_empty() {
        println!("Never switch: {}", never.join(", "));
    }
    Ok(())
}

fn group(store: &Store, action: GroupAction) -> CliResult {
    let auto = AutoSwitch::new(store);
    let mut settings = auto.saved_settings().map_err(|e| e.to_string())?;
    let target =
        |settings: &AutoSwitchSettings, reference: &str| -> Result<Option<uuid::Uuid>, String> {
            if reference.eq_ignore_ascii_case("none") {
                Ok(None)
            } else {
                settings.find(reference).map(Some)
            }
        };
    match action {
        GroupAction::Add { name } => settings.groups.push(FallbackGroup::new(&name, &[])),
        GroupAction::Remove { group } => {
            let id = settings.find(&group)?;
            settings.remove_group(id);
        }
        GroupAction::Rename { group, name } => {
            let id = settings.find(&group)?;
            if let Some(group) = settings.group_mut(id) {
                group.name = name;
            }
        }
        GroupAction::Move { account, group } => {
            if !store.exists(&account) {
                return Err(format!("No saved account called “{account}”."));
            }
            let id = target(&settings, &group)?;
            settings.move_member(&account, id);
        }
        GroupAction::Next { group, next } => {
            let id = settings.find(&group)?;
            let next = target(&settings, &next)?;
            if next == Some(id) {
                return Err("A group can't fall back to itself.".to_string());
            }
            if let Some(group) = settings.group_mut(id) {
                group.next = next;
            }
        }
    }
    auto.save(&settings).map_err(|e| e.to_string())?;
    show_auto_switch(store, false)
}

fn limit_reached(store: &Store) {
    let mut input = String::new();
    let _ = io::stdin().read_to_string(&mut input);
    let message = serde_json::from_str::<Value>(&input)
        .ok()
        .and_then(|event| {
            event
                .get("last_assistant_message")?
                .as_str()
                .map(String::from)
        })
        .unwrap_or_default();
    store.import_cached_usage();
    let auto = AutoSwitch::new(store);
    let now = Utc::now();
    let outcome = auto.handle_limit(&message, now);
    auto.log(&outcome, now);
    if !matches!(outcome, Outcome::Ignored(_)) {
        after_auto_switch(&auto);
    }
}

fn after_auto_switch(auto: &AutoSwitch) {
    if let Err(error) = platform::schedule_retry(auto.pending_retry()) {
        auto.log_line(
            &format!("couldn't schedule the next try: {error}"),
            Utc::now(),
        );
    }
    platform::notify_changed();
}

#[cfg(target_os = "macos")]
mod platform {
    use std::ffi::{c_char, c_void, CString};

    use chrono::{DateTime, Utc};

    #[link(name = "CoreFoundation", kind = "framework")]
    extern "C" {
        fn CFNotificationCenterGetDistributedCenter() -> *const c_void;
        fn CFStringCreateWithCString(
            allocator: *const c_void,
            text: *const c_char,
            encoding: u32,
        ) -> *const c_void;
        fn CFNotificationCenterPostNotification(
            center: *const c_void,
            name: *const c_void,
            object: *const c_void,
            user_info: *const c_void,
            deliver_immediately: u8,
        );
        fn CFRelease(object: *const c_void);
    }

    const UTF8: u32 = 0x0800_0100;

    pub fn notify_changed() {
        let Ok(name) = CString::new("com.danielgriffiths.SwapBot.changed") else {
            return;
        };
        unsafe {
            let name = CFStringCreateWithCString(std::ptr::null(), name.as_ptr(), UTF8);
            if name.is_null() {
                return;
            }
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDistributedCenter(),
                name,
                std::ptr::null(),
                std::ptr::null(),
                1,
            );
            CFRelease(name);
        }
    }

    pub fn schedule_retry(_: Option<DateTime<Utc>>) -> Result<(), String> {
        Ok(())
    }
}

#[cfg(not(target_os = "macos"))]
mod platform {
    use std::time::Duration;

    use chrono::{DateTime, Utc};
    use swapbot::system;

    const UNIT: &str = "swapbot-retry";

    pub fn notify_changed() {}

    pub fn schedule_retry(at: Option<DateTime<Utc>>) -> Result<(), String> {
        let timeout = Duration::from_secs(10);
        system::run(
            "systemctl",
            &["--user", "stop", &format!("{UNIT}.timer")],
            timeout,
            None,
        );
        let Some(at) = at else { return Ok(()) };
        let executable = super::executable()?;
        let output = system::run(
            "systemd-run",
            &[
                "--user".to_string(),
                "--collect".to_string(),
                format!("--unit={UNIT}"),
                format!("--on-calendar={} UTC", at.format("%Y-%m-%d %H:%M:%S")),
                "--timer-property=AccuracySec=1s".to_string(),
                executable.to_string_lossy().into_owned(),
                "auto-switch".to_string(),
                "retry".to_string(),
            ],
            timeout,
            None,
        );
        if output.status == 0 {
            Ok(())
        } else {
            Err(format!("systemd-run: {}", output.stderr.trim()))
        }
    }
}
