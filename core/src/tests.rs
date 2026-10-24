use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::Command;
use std::thread;
use std::time::{Duration, Instant};

use chrono::{DateTime, TimeDelta, Utc};
use serde_json::{json, Value};
use uuid::Uuid;

use crate::auto_switch::{AutoSwitch, AutoSwitchSettings, FallbackGroup, Outcome, State};
use crate::credentials::{CredentialFiles, Slot};
use crate::error::Error;
use crate::hooks::Hooks;
use crate::json::{compact, parse_object, Object};
use crate::models::{natural_cmp, suggested_name, AccountInfo, Profile, TokenInfo};
use crate::processes;
use crate::store::{Paths, Store};
use crate::system;
use crate::usage::{parse_reset, Usage, UsageWindow};

fn date(text: &str) -> DateTime<Utc> {
    crate::dates::parse(text).unwrap()
}

struct Fixture {
    dir: PathBuf,
    store: Store,
}

impl Fixture {
    fn new() -> Fixture {
        let dir = std::env::temp_dir().join(format!("swapbot-test-{}", Uuid::new_v4()));
        fs::create_dir_all(&dir).unwrap();
        let paths = Paths {
            service: "unused".to_string(),
            profile_dir: dir.join("profiles"),
            claude_json: dir.join("claude.json"),
            claude_settings: dir.join("settings.json"),
            credentials_file: dir.join(".credentials.json"),
        };
        let credentials =
            CredentialFiles::new(paths.credentials_file.clone(), paths.profile_dir.clone());
        Fixture {
            dir,
            store: Store::new(paths, Box::new(credentials)),
        }
    }

    fn work() -> Value {
        json!({"accountUuid": "acc-work", "organizationUuid": "org-work", "emailAddress": "me@work.example", "organizationName": "Work"})
    }

    fn work2() -> Value {
        json!({"accountUuid": "acc-work2", "organizationUuid": "org-work", "emailAddress": "me2@work.example", "organizationName": "Work"})
    }

    fn personal() -> Value {
        json!({"accountUuid": "acc-me", "organizationUuid": "org-me", "emailAddress": "me@home.example", "organizationName": "Me"})
    }

    fn login(&self, account: Value, user: &str, access: &str, refresh: &str) {
        self.login_with_mcp(account, user, access, refresh, "mcp-token");
    }

    fn login_with_mcp(&self, account: Value, user: &str, access: &str, refresh: &str, mcp: &str) {
        let live = json!({
            "claudeAiOauth": {"accessToken": access, "refreshToken": refresh, "expiresAt": 1_900_000_000_000u64,
                              "refreshTokenExpiresAt": 1_900_000_000_000u64, "subscriptionType": "max"},
            "mcpOAuth": {"server": {"accessToken": mcp}},
        });
        self.store
            .credentials
            .write(&Slot::Live, &live.to_string())
            .unwrap();
        let mut config = self.store.read_claude_json().unwrap_or_else(|_| {
            parse_object(r#"{"numStartups": 3, "projects": {"/tmp": {"allowedTools": []}}}"#)
                .unwrap()
        });
        config.insert("oauthAccount".to_string(), account);
        config.insert("userID".to_string(), json!(user));
        fs::write(&self.store.paths.claude_json, compact(&config)).unwrap();
    }

    fn live(&self) -> Object {
        parse_object(&self.store.credentials.read(&Slot::Live).unwrap().unwrap()).unwrap()
    }

    fn live_oauth(&self, key: &str) -> Option<String> {
        self.live()
            .get("claudeAiOauth")?
            .get(key)?
            .as_str()
            .map(String::from)
    }

    fn names(&self) -> Vec<String> {
        self.store
            .profiles(true)
            .into_iter()
            .map(|p| p.name)
            .collect()
    }

    fn active(&self) -> Option<String> {
        self.store.active_profile().map(|p| p.name)
    }

    fn profile(&self, name: &str) -> Profile {
        self.store
            .profiles(true)
            .into_iter()
            .find(|p| p.name == name)
            .unwrap()
    }

    fn save_accounts(&self) {
        self.login(Self::work2(), "u-work2", "a-work2", "r-work2");
        self.store.save("work2", false).unwrap();
        self.login(Self::personal(), "u-me", "a-me", "r-me");
        self.store.save("personal", false).unwrap();
        self.login(Self::work(), "u-work", "a-work", "r-work");
        self.store.save("work", false).unwrap();
    }

    fn exhaust(&self, name: &str, until: DateTime<Utc>) {
        self.store.record_usage(name, || {
            Some(Usage::new(
                vec![UsageWindow::new("Session", 100.0, Some(until))],
                until,
            ))
        });
    }

    fn auto_switch(&self) -> AutoSwitch<'_> {
        AutoSwitch::new(&self.store)
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.dir);
    }
}

#[test]
fn save_and_switch_round_trip() {
    let f = Fixture::new();
    f.login(Fixture::work(), "u-work", "a-work", "r-work");
    f.store.save("work", false).unwrap();
    f.login_with_mcp(Fixture::personal(), "u-me", "a-me", "r-me", "mcp-latest");
    f.store.save("personal", false).unwrap();

    assert_eq!(f.names(), ["personal", "work"]);
    assert_eq!(f.active().as_deref(), Some("personal"));

    f.store.switch_to("work").unwrap();
    assert_eq!(f.live_oauth("accessToken").as_deref(), Some("a-work"));
    assert_eq!(f.live_oauth("refreshToken").as_deref(), Some("r-work"));
    assert_eq!(f.live()["mcpOAuth"]["server"]["accessToken"], "mcp-latest");
    let config = f.store.read_claude_json().unwrap();
    assert_eq!(config["oauthAccount"]["emailAddress"], "me@work.example");
    assert_eq!(config["userID"], "u-work");
    assert_eq!(config["numStartups"], 3);
    assert!(config.contains_key("projects"));
    assert_eq!(f.active().as_deref(), Some("work"));
}

#[test]
fn switching_resaves_rotated_tokens_of_outgoing_account() {
    let f = Fixture::new();
    f.login(Fixture::work(), "u-work", "a-work", "r-work");
    f.store.save("work", false).unwrap();
    f.login(Fixture::personal(), "u-me", "a-me", "r-me");
    f.store.save("personal", false).unwrap();
    f.login(Fixture::personal(), "u-me", "a-me-2", "r-me-2");

    f.store.switch_to("work").unwrap();
    f.store.switch_to("personal").unwrap();
    assert_eq!(f.live_oauth("refreshToken").as_deref(), Some("r-me-2"));
}

#[test]
fn empty_live_tokens_never_clobber_a_snapshot() {
    let f = Fixture::new();
    f.login(Fixture::work(), "u-work", "a-work", "r-work");
    f.store.save("work", false).unwrap();
    f.login(Fixture::work(), "u-work", "", "");

    assert_eq!(f.store.save("work", true), Err(Error::EmptyLiveTokens));
    assert_eq!(
        f.store.snapshot_oauth("work").unwrap()["refreshToken"],
        "r-work"
    );
}

#[test]
fn refuses_empty_snapshots_and_duplicates() {
    let f = Fixture::new();
    f.login(Fixture::work(), "u-work", "a-work", "r-work");
    f.store.save("work", false).unwrap();
    assert_eq!(
        f.store.save("work", false),
        Err(Error::AlreadyExists("work".into()))
    );
    assert_eq!(
        f.store.save("bad name", false),
        Err(Error::InvalidName("bad name".into()))
    );
    assert_eq!(
        f.store.switch_to("nope"),
        Err(Error::NoSuchProfile("nope".into()))
    );

    f.store
        .credentials
        .write(
            &Slot::Saved("work".into()),
            r#"{"claudeAiOauth":{"accessToken":"","refreshToken":""}}"#,
        )
        .unwrap();
    f.login(Fixture::personal(), "u-me", "a-me", "r-me");
    assert_eq!(
        f.store.switch_to("work"),
        Err(Error::EmptySnapshot("work".into()))
    );
    assert_eq!(f.live_oauth("accessToken").as_deref(), Some("a-me"));
}

#[test]
fn rename_and_remove() {
    let f = Fixture::new();
    f.login(Fixture::personal(), "u-me", "a-me", "r-me");
    f.store.save("personal", false).unwrap();
    f.store.rename("personal", "home").unwrap();

    assert_eq!(f.names(), ["home"]);
    assert_eq!(
        f.store
            .credentials
            .read(&Slot::Saved("personal".into()))
            .unwrap(),
        None
    );
    assert!(f.profile("home").tokens.unwrap().has_tokens);
    assert_eq!(f.active().as_deref(), Some("home"));

    f.store.remove("home").unwrap();
    assert!(f.names().is_empty());
    assert_eq!(
        f.store
            .credentials
            .read(&Slot::Saved("home".into()))
            .unwrap(),
        None
    );
    assert_eq!(f.live_oauth("accessToken").as_deref(), Some("a-me"));
}

#[test]
fn fingerprint_changes_on_new_login_even_for_same_account() {
    let f = Fixture::new();
    f.login(Fixture::work(), "u-work", "a-work", "r-work");
    let before = f.store.fingerprint();
    assert_eq!(f.store.fingerprint(), before);
    f.login(Fixture::work(), "u-work", "a-work-2", "r-work-2");
    assert_ne!(f.store.fingerprint(), before);
}

#[test]
fn large_blobs_round_trip() {
    let f = Fixture::new();
    let big = "x".repeat(20_000);
    f.login_with_mcp(Fixture::work(), "u-work", &big, "r", &big);
    f.store.save("work", false).unwrap();
    assert_eq!(
        f.store.snapshot_oauth("work").unwrap()["accessToken"],
        big.as_str()
    );
}

#[test]
fn saved_credential_files_are_private() {
    let f = Fixture::new();
    f.login(Fixture::work(), "u-work", "a-work", "r-work");
    f.store.save("work", false).unwrap();
    let path = f.store.paths.profile_dir.join("work.credentials.json");
    assert_eq!(
        fs::metadata(&path).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert_eq!(
        fs::metadata(&f.store.paths.credentials_file)
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
}

#[test]
fn switching_keeps_the_rest_of_claude_json_in_order() {
    let f = Fixture::new();
    f.login(Fixture::work(), "u-work", "a-work", "r-work");
    f.store.save("work", false).unwrap();
    f.login(Fixture::personal(), "u-me", "a-me", "r-me");
    fs::write(
        &f.store.paths.claude_json,
        r#"{"zeta": 1, "oauthAccount": {"accountUuid": "acc-me", "organizationUuid": "org-me", "emailAddress": "me@home.example"}, "big": 12345678901234567890, "ratio": 0.1, "alpha": "a/b"}"#,
    )
    .unwrap();
    f.store.switch_to("work").unwrap();
    let text = fs::read_to_string(&f.store.paths.claude_json).unwrap();
    let keys: Vec<&str> = [
        "\"zeta\"",
        "\"oauthAccount\"",
        "\"big\"",
        "\"ratio\"",
        "\"alpha\"",
        "\"userID\"",
    ]
    .into_iter()
    .filter(|k| text.contains(k))
    .collect();
    let positions: Vec<usize> = keys.iter().map(|k| text.find(k).unwrap()).collect();
    assert!(positions.windows(2).all(|w| w[0] < w[1]), "{text}");
    assert!(text.contains("12345678901234567890"));
    assert!(text.contains("0.1"));
    assert!(text.contains("\"a/b\""));
}

#[test]
fn unreadable_live_login_is_never_overwritten() {
    let f = Fixture::new();
    f.login(Fixture::work(), "u-work", "a-work", "r-work");
    f.store.save("work", false).unwrap();
    f.login(Fixture::personal(), "u-me", "a-me", "r-me");
    f.store.credentials.write(&Slot::Live, "not json").unwrap();
    assert!(matches!(
        f.store.switch_to("work"),
        Err(Error::Credentials(_))
    ));
    assert_eq!(
        f.store.credentials.read(&Slot::Live).unwrap().as_deref(),
        Some("not json")
    );
}

#[test]
fn records_usage_for_an_account_and_keeps_it_through_rename() {
    let f = Fixture::new();
    f.login(Fixture::work(), "u-work", "a-work", "r-work");
    f.store.save("work", false).unwrap();
    let now = Utc::now();
    let recorded = f.store.record_usage("work", || {
        Some(Usage::new(
            vec![
                UsageWindow::new("Session", 73.0, None),
                UsageWindow::new("Week", 91.0, None),
            ],
            now,
        ))
    });
    assert_eq!(recorded.unwrap().windows[0].percent, 73.0);
    assert_eq!(f.profile("work").usage.unwrap().windows[1].percent, 91.0);

    f.store.rename("work", "job").unwrap();
    assert_eq!(f.profile("job").usage.unwrap().windows[0].percent, 73.0);
    f.store.remove("job").unwrap();
    assert!(!f.store.usage_path("job").exists());
}

#[test]
fn failed_usage_fetch_records_nothing() {
    let f = Fixture::new();
    f.login(Fixture::work(), "u-work", "a-work", "r-work");
    f.store.save("work", false).unwrap();
    assert_eq!(f.store.record_usage("work", || None), None);
    assert_eq!(f.profile("work").usage, None);
}

#[test]
fn usage_files_match_the_swift_format() {
    let f = Fixture::new();
    f.login(Fixture::work(), "u-work", "a-work", "r-work");
    f.store.save("work", false).unwrap();
    let swift = r#"{
  "recordedAt" : "2026-10-17T11:15:00Z",
  "windows" : [
    {
      "name" : "Session",
      "percent" : 100,
      "resetsAt" : "2026-10-17T14:20:00Z",
      "resetsText" : "3:20pm"
    },
    {
      "name" : "Week",
      "percent" : 12.5
    }
  ]
}"#;
    fs::write(f.store.usage_path("work"), swift).unwrap();
    let usage = f.profile("work").usage.unwrap();
    assert_eq!(usage.recorded_at, date("2026-10-17T11:15:00Z"));
    assert_eq!(
        usage.windows[0].resets_at,
        Some(date("2026-10-17T14:20:00Z"))
    );
    assert_eq!(usage.windows[1].percent, 12.5);

    f.store.write_usage(&usage, "work");
    let written: Value =
        serde_json::from_str(&fs::read_to_string(f.store.usage_path("work")).unwrap()).unwrap();
    assert_eq!(written["recordedAt"], "2026-10-17T11:15:00Z");
    assert_eq!(written["windows"][0]["resetsAt"], "2026-10-17T14:20:00Z");
    assert!(written["windows"][1].get("resetsAt").is_none());
}

#[test]
fn parses_claude_usage_output() {
    let output = "You are currently using your subscription to power your Claude Code usage

Current session: 92% used · resets Oct 15 at 11:20pm (Europe/London)
Current week (Fable): 0% used · resets Oct 18 at 10am (Europe/London)

What's contributing to your limits usage?
Last 24h · 13512 requests · 18 sessions
  95% of your usage was at >150k context
";
    let now = date("2026-10-15T21:00:00Z");
    let usage = Usage::from_claude_output(output, now).unwrap();
    let names: Vec<&str> = usage.windows.iter().map(|w| w.name.as_str()).collect();
    assert_eq!(names, ["Session", "Week (Fable)"]);
    assert_eq!(
        usage.windows.iter().map(|w| w.percent).collect::<Vec<_>>(),
        [92.0, 0.0]
    );
    assert_eq!(
        usage.windows[0].resets_text.as_deref(),
        Some("Oct 15 at 11:20pm")
    );
    assert_eq!(
        usage.windows[1].resets_text.as_deref(),
        Some("Oct 18 at 10am")
    );
    assert_eq!(
        usage.windows[0].resets_at,
        Some(date("2026-10-15T22:20:00Z"))
    );
    assert_eq!(
        usage.windows[1].resets_at,
        Some(date("2026-10-18T09:00:00Z"))
    );
    assert_eq!(
        Usage::from_claude_output("Unknown command: /usage", now),
        None
    );
}

#[test]
fn reset_times_without_a_date_roll_into_tomorrow() {
    let now = date("2026-10-17T16:00:00Z");
    assert_eq!(
        parse_reset("3:20pm (Europe/London)", now),
        Some(date("2026-10-18T14:20:00Z"))
    );
    assert_eq!(
        parse_reset("6pm (America/New_York)", now),
        Some(date("2026-10-17T22:00:00Z"))
    );
    assert_eq!(
        parse_reset("Oct 25, 2027 at 6pm (UTC)", now),
        Some(date("2027-10-25T18:00:00Z"))
    );
    assert_eq!(parse_reset("soon", now), None);
}

#[test]
fn only_accounts_in_the_same_organization_share_prompt_cache() {
    let account = |a: &str, org: Option<&str>| {
        let mut value = json!({"accountUuid": a});
        if let Some(org) = org {
            value["organizationUuid"] = json!(org);
        }
        AccountInfo::from_json(Some(&value)).unwrap()
    };
    let alice = account("a", Some("team"));
    let bob = account("b", Some("team"));
    let personal = account("a", Some("solo"));
    assert!(alice.shares_prompt_cache(&bob));
    assert!(!alice.shares_prompt_cache(&personal));
    assert!(!account("c", None).shares_prompt_cache(&account("d", None)));
}

#[test]
fn usage_resets_in_january_roll_into_next_year() {
    let now = date("2026-12-30T12:00:00Z");
    assert_eq!(
        parse_reset("Jan 2 at 9am (Europe/London)", now),
        Some(date("2027-01-02T09:00:00Z"))
    );
}

#[test]
fn shell_gives_up_on_hung_commands() {
    let start = Instant::now();
    let output = system::run("/bin/sleep", &["30"], Duration::from_millis(500), None);
    assert!(output.timed_out);
    assert!(start.elapsed() < Duration::from_secs(3));
}

#[test]
fn terminate_stops_processes_that_ignore_sigterm() {
    let spawn = |script: &str| {
        let mut child = Command::new("/bin/sh")
            .args(["-c", script])
            .spawn()
            .unwrap();
        let pid = child.id() as i32;
        thread::spawn(move || child.wait());
        pid
    };
    let polite = spawn("exec sleep 60");
    let stubborn = spawn("trap '' TERM; while :; do sleep 0.1; done");
    thread::sleep(Duration::from_millis(200));
    assert!(processes::is_running(polite) && processes::is_running(stubborn));
    let survivors = processes::terminate(&[polite, stubborn], Duration::from_secs(1));
    assert!(survivors.is_empty());
    thread::sleep(Duration::from_millis(100));
    assert!(!processes::is_running(polite) && !processes::is_running(stubborn));
}

#[test]
fn names_sort_like_finder() {
    let mut names = vec![
        "work",
        "daniel_3",
        "Daniel_10",
        "daniel",
        "daniel_2",
        "personal",
    ];
    names.sort_by(|a, b| natural_cmp(a, b));
    assert_eq!(
        names,
        [
            "daniel",
            "daniel_2",
            "daniel_3",
            "Daniel_10",
            "personal",
            "work"
        ]
    );
}

#[test]
fn suggested_names_are_valid_and_unique() {
    assert_eq!(
        suggested_name(Some("jordan@zerodivide.ltd"), |_| false),
        "jordan"
    );
    assert_eq!(
        suggested_name(Some("daniel.griffiths+x@gmail.com"), |n| n
            == "daniel.griffiths-x"),
        "daniel.griffiths-x-2"
    );
    assert_eq!(suggested_name(Some("+me@example.com"), |_| false), "me");
    assert_eq!(suggested_name(None, |_| false), "account");
    assert!(Store::validate(&suggested_name(
        Some(&format!("{}@x.com", "a".repeat(60))),
        |_| false
    ))
    .is_ok());
}

#[test]
fn usage_limit_switches_to_the_least_used_account_in_the_group() {
    let f = Fixture::new();
    f.save_accounts();
    let auto = f.auto_switch();
    auto.save(&AutoSwitchSettings {
        groups: vec![FallbackGroup::new("Work", &["work", "work2"])],
    })
    .unwrap();
    let now = date("2026-10-17T11:15:00Z");

    let outcome = auto.handle_limit(
        "You've hit your session limit · resets 3:20pm (Europe/London)",
        now,
    );
    assert_eq!(
        outcome,
        Outcome::Switched {
            from: "work".into(),
            to: "work2".into()
        }
    );
    assert_eq!(f.active().as_deref(), Some("work2"));
    let session = f.profile("work").usage.unwrap().windows[0].clone();
    assert_eq!(session.percent, 100.0);
    assert_eq!(session.resets_at, Some(date("2026-10-17T14:20:00Z")));

    let again = auto.handle_limit(
        "You've hit your session limit · resets 3:20pm (Europe/London)",
        now + TimeDelta::seconds(5),
    );
    assert_eq!(again, Outcome::Ignored("switched 5s ago".into()));
    assert_eq!(f.active().as_deref(), Some("work2"));
    assert_eq!(f.profile("work2").usage, None);
}

#[test]
fn usage_limit_moves_to_the_next_group_only_when_the_group_is_used_up() {
    let f = Fixture::new();
    f.save_accounts();
    let auto = f.auto_switch();
    let now = date("2026-10-17T11:15:00Z");
    auto.save(&AutoSwitchSettings {
        groups: vec![FallbackGroup::new("Home", &["personal"])],
    })
    .unwrap();
    assert_eq!(
        auto.handle_limit("You've hit your session limit · resets 3:20pm", now),
        Outcome::Ignored("“work” hit its session limit; it isn't in a fallback group".into())
    );

    let home = FallbackGroup::new("Home", &["personal"]);
    let mut work = FallbackGroup::new("Work", &["work", "work2"]);
    auto.save(&AutoSwitchSettings {
        groups: vec![work.clone(), home.clone()],
    })
    .unwrap();
    f.store.record_usage("work2", || {
        Some(Usage::new(
            vec![UsageWindow::new(
                "Week",
                100.0,
                Some(now + TimeDelta::hours(1)),
            )],
            now,
        ))
    });
    assert_eq!(
        auto.handle_limit("You've hit your weekly limit · resets Oct 25 at 6pm", now),
        Outcome::Waiting {
            reason: "“work” hit its week limit and everything it can switch to is used up".into(),
            until: now + TimeDelta::hours(1)
        }
    );

    work.next = Some(home.id);
    auto.save(&AutoSwitchSettings {
        groups: vec![work, home],
    })
    .unwrap();
    assert_eq!(
        auto.handle_limit("You've hit your weekly limit", now),
        Outcome::Switched {
            from: "work".into(),
            to: "personal".into()
        }
    );
}

#[test]
fn server_rate_limits_dont_count() {
    let f = Fixture::new();
    f.save_accounts();
    let auto = f.auto_switch();
    auto.save(&AutoSwitchSettings {
        groups: vec![FallbackGroup::new("All", &["work", "work2", "personal"])],
    })
    .unwrap();
    assert_eq!(
        auto.handle_limit("API Error: Rate limit reached", Utc::now()),
        Outcome::Ignored("not a usage limit: API Error: Rate limit reached".into())
    );
    assert_eq!(f.active().as_deref(), Some("work"));
}

#[test]
fn fallback_skips_used_up_and_expired_accounts_and_stops_at_loops() {
    let now = Utc::now();
    let profile = |name: &str,
                   percent: Option<f64>,
                   resets_at: Option<DateTime<Utc>>,
                   expired: bool| {
        let expiry = if expired {
            now - TimeDelta::seconds(60)
        } else {
            now + TimeDelta::days(1)
        };
        let tokens = json!({"accessToken": "a", "refreshToken": "r", "refreshTokenExpiresAt": expiry.timestamp_millis()});
        Profile {
            name: name.to_string(),
            account: AccountInfo::from_json(Some(
                &json!({"accountUuid": name, "organizationUuid": "org"}),
            )),
            tokens: Some(TokenInfo::from_oauth(tokens.as_object().unwrap())),
            usage: percent
                .map(|p| Usage::new(vec![UsageWindow::new("Session", p, resets_at)], now)),
        }
    };
    let active = profile("a", Some(100.0), None, false);
    let profiles = vec![
        active.clone(),
        profile("b", Some(40.0), None, false),
        profile("c", Some(100.0), Some(now - TimeDelta::seconds(60)), false),
        profile("d", Some(0.0), None, true),
        profile("e", None, None, false),
        profile("f", Some(100.0), Some(now + TimeDelta::hours(1)), false),
    ];
    let pick = |settings: &AutoSwitchSettings, from: &Profile| {
        AutoSwitch::fallback(from, &profiles, settings, now).map(|p| p.name.clone())
    };
    let mut first = FallbackGroup::new("First", &["a", "b", "c", "d"]);
    let mut second = FallbackGroup::new("Second", &["e", "f"]);
    let settings = |first: &FallbackGroup, second: &FallbackGroup| AutoSwitchSettings {
        groups: vec![first.clone(), second.clone()],
    };
    assert_eq!(
        pick(&settings(&first, &second), &active).as_deref(),
        Some("c")
    );

    first.members = vec!["a".into(), "d".into(), "f".into()];
    assert_eq!(pick(&settings(&first, &second), &active), None);
    first.next = Some(second.id);
    second.next = Some(first.id);
    assert_eq!(
        pick(&settings(&first, &second), &active).as_deref(),
        Some("e")
    );
    second.members = vec!["f".into()];
    assert_eq!(pick(&settings(&first, &second), &active), None);
    assert_eq!(
        pick(
            &settings(&first, &second),
            &profile("z", Some(100.0), None, false)
        ),
        None
    );
}

#[test]
fn default_groups_follow_organizations_and_track_renames_and_removals() {
    let f = Fixture::new();
    f.save_accounts();
    let auto = f.auto_switch();
    let defaults = auto.settings();
    assert_eq!(
        defaults
            .groups
            .iter()
            .map(|g| g.name.as_str())
            .collect::<Vec<_>>(),
        ["Me", "Work"]
    );
    assert_eq!(
        defaults
            .groups
            .iter()
            .map(|g| g.members.clone())
            .collect::<Vec<_>>(),
        [vec!["personal"], vec!["work", "work2"]]
    );

    auto.save(&defaults).unwrap();
    f.store.rename("work2", "home").unwrap();
    assert_eq!(
        auto.settings().group_containing("home").unwrap().name,
        "Work"
    );
    f.store.remove("home").unwrap();
    assert_eq!(
        auto.settings()
            .groups
            .iter()
            .map(|g| g.members.clone())
            .collect::<Vec<_>>(),
        [vec!["personal"], vec!["work"]]
    );

    let mut settings = auto.settings();
    let work = settings.group_containing("work").unwrap().id;
    settings.groups[0].next = Some(work);
    settings.move_member("personal", Some(work));
    settings.remove_group(work);
    assert_eq!(settings.groups.len(), 1);
    assert_eq!(settings.groups[0].next, None);
    assert!(settings.group_containing("personal").is_none());
}

#[test]
fn reads_settings_saved_by_the_swift_app() {
    let f = Fixture::new();
    f.save_accounts();
    fs::write(
        f.auto_switch().settings_path(),
        r#"{
  "groups" : [
    {
      "id" : "8D3F8E0A-6C2B-4C51-9E33-1B2A4F5D6E70",
      "members" : [ "work", "work2" ],
      "name" : "Work",
      "next" : "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"
    },
    {
      "id" : "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D",
      "members" : [ "personal" ],
      "name" : "Personal"
    }
  ]
}"#,
    )
    .unwrap();
    let settings = f.auto_switch().settings();
    assert_eq!(settings.groups.len(), 2);
    assert_eq!(
        settings.group(settings.groups[0].next).unwrap().name,
        "Personal"
    );
    assert_eq!(
        settings.find("8d3f8e0a-6c2b-4c51-9e33-1b2a4f5d6e70"),
        Ok(settings.groups[0].id)
    );
    assert_eq!(settings.find("personal"), Ok(settings.groups[1].id));
    assert!(settings.find("nope").is_err());
    assert_eq!(
        settings
            .ordered()
            .iter()
            .map(|g| g.name.as_str())
            .collect::<Vec<_>>(),
        ["Work", "Personal"]
    );
}

#[test]
fn imports_usage_claude_code_cached_for_the_matching_account() {
    let f = Fixture::new();
    f.save_accounts();
    let mut config = f.store.read_claude_json().unwrap();
    config.insert(
        "cachedUsageUtilization".to_string(),
        json!({
            "accountUuid": "acc-me",
            "fetchedAtMs": 1_792_796_588_055u64,
            "utilization": {
                "five_hour": {"utilization": 77, "resets_at": "2026-10-24T01:39:59.896789+00:00"},
                "seven_day": {"utilization": 84, "resets_at": "2026-10-25T17:59:59.896807+00:00"},
                "seven_day_opus": null,
            },
        }),
    );
    fs::write(&f.store.paths.claude_json, compact(&config)).unwrap();

    assert_eq!(f.store.import_cached_usage().as_deref(), Some("personal"));
    let usage = f.profile("personal").usage.unwrap();
    assert_eq!(
        usage
            .windows
            .iter()
            .map(|w| w.name.as_str())
            .collect::<Vec<_>>(),
        ["Session", "Week"]
    );
    assert_eq!(
        usage.windows.iter().map(|w| w.percent).collect::<Vec<_>>(),
        [77.0, 84.0]
    );
    assert_eq!(
        usage.windows[0].resets_at,
        Some(date("2026-10-24T01:39:59Z"))
    );
    assert_eq!(f.store.import_cached_usage(), None);
}

#[test]
fn hook_install_keeps_other_hooks_and_removes_only_its_own() {
    let f = Fixture::new();
    let hooks = Hooks::new(f.store.paths.claude_settings.clone());
    let existing = json!({
        "model": "opus",
        "hooks": {
            "Stop": [{"hooks": [{"type": "command", "command": "say done"}]}],
            "StopFailure": [
                {"matcher": "rate_limit", "hooks": [{"type": "command", "command": "say limited"}]},
                {"matcher": "rate_limit", "hooks": [{"type": "command", "command": "'/Applications/SwapBot.app/Contents/MacOS/SwapBot' --limit-reached", "timeout": 30}]},
            ],
        },
    });
    fs::write(&hooks.settings, existing.to_string()).unwrap();

    assert_eq!(
        hooks.installed_command().as_deref(),
        Some("'/Applications/SwapBot.app/Contents/MacOS/SwapBot' --limit-reached")
    );
    hooks
        .install(&PathBuf::from(
            "/Users/me/Applications/SwapBot.app/Contents/Helpers/swapbot",
        ))
        .unwrap();
    hooks
        .install(&PathBuf::from("/home/me/.cargo/bin/swapbot"))
        .unwrap();
    assert_eq!(
        hooks.installed_command().as_deref(),
        Some("'/home/me/.cargo/bin/swapbot' limit-reached")
    );
    let settings = hooks.read().unwrap();
    assert_eq!(
        settings["hooks"]["StopFailure"].as_array().unwrap().len(),
        2
    );
    assert_eq!(settings.keys().collect::<Vec<_>>(), ["model", "hooks"]);

    assert!(!hooks
        .refresh(&PathBuf::from("/home/me/.cargo/bin/swapbot"))
        .unwrap());
    assert!(hooks
        .refresh(&PathBuf::from("/usr/local/bin/swapbot"))
        .unwrap());
    assert_eq!(
        hooks.installed_command().as_deref(),
        Some("'/usr/local/bin/swapbot' limit-reached")
    );

    hooks.uninstall().unwrap();
    assert_eq!(hooks.installed_command(), None);
    let settings = hooks.read().unwrap();
    assert_eq!(
        settings["hooks"]["StopFailure"].as_array().unwrap().len(),
        1
    );
    assert!(settings["hooks"].get("Stop").is_some());
    assert_eq!(settings["model"], "opus");
}

#[test]
fn hook_install_leaves_invalid_settings_alone() {
    let f = Fixture::new();
    fs::write(&f.store.paths.claude_settings, "{ not json").unwrap();
    let hooks = Hooks::new(f.store.paths.claude_settings.clone());
    assert!(matches!(
        hooks.install(&PathBuf::from("/usr/local/bin/swapbot")),
        Err(Error::Settings(_))
    ));
    assert_eq!(
        fs::read_to_string(&f.store.paths.claude_settings).unwrap(),
        "{ not json"
    );
}

#[test]
fn hook_uninstall_removes_empty_sections() {
    let f = Fixture::new();
    let hooks = Hooks::new(f.store.paths.claude_settings.clone());
    hooks
        .install(&PathBuf::from("/usr/local/bin/swapbot"))
        .unwrap();
    hooks.uninstall().unwrap();
    assert!(hooks.read().unwrap().is_empty());
}

#[test]
fn waits_for_the_earliest_reset_in_the_chain_then_switches() {
    let f = Fixture::new();
    f.save_accounts();
    let auto = f.auto_switch();
    let home = FallbackGroup::new("Home", &["personal"]);
    let mut work = FallbackGroup::new("Work", &["work", "work2"]);
    work.next = Some(home.id);
    auto.save(&AutoSwitchSettings {
        groups: vec![work, home],
    })
    .unwrap();
    let now = date("2026-10-17T11:15:00Z");
    f.exhaust("work2", now + TimeDelta::hours(2));
    f.exhaust("personal", now + TimeDelta::hours(1));

    let outcome = auto.handle_limit(
        "You've hit your session limit · resets 3:20pm (Europe/London)",
        now,
    );
    assert_eq!(
        outcome,
        Outcome::Waiting {
            reason: "“work” hit its session limit and everything it can switch to is used up"
                .into(),
            until: now + TimeDelta::hours(1)
        }
    );
    assert_eq!(auto.pending_retry(), Some(now + TimeDelta::hours(1)));
    assert_eq!(f.active().as_deref(), Some("work"));

    assert_eq!(
        auto.retry(now + TimeDelta::seconds(3601)),
        Outcome::Switched {
            from: "work".into(),
            to: "personal".into()
        }
    );
    assert_eq!(auto.pending_retry(), None);
}

#[test]
fn doesnt_wait_when_the_current_account_resets_first() {
    let f = Fixture::new();
    f.save_accounts();
    let auto = f.auto_switch();
    auto.save(&AutoSwitchSettings {
        groups: vec![FallbackGroup::new("Work", &["work", "work2"])],
    })
    .unwrap();
    let now = date("2026-10-17T11:15:00Z");
    f.exhaust("work2", now + TimeDelta::hours(5));

    let outcome = auto.handle_limit(
        "You've hit your session limit · resets 3:20pm (Europe/London)",
        now,
    );
    assert_eq!(
        outcome,
        Outcome::Ignored(
            "“work” hit its session limit; nothing it can switch to resets before it does".into()
        )
    );
    assert_eq!(auto.pending_retry(), None);
}

#[test]
fn retry_leaves_an_account_that_has_usage_again() {
    let f = Fixture::new();
    f.save_accounts();
    let auto = f.auto_switch();
    auto.save(&AutoSwitchSettings {
        groups: vec![FallbackGroup::new("Work", &["work", "work2"])],
    })
    .unwrap();
    let now = DateTime::from_timestamp(Utc::now().timestamp(), 0).unwrap();
    f.exhaust("work", now - TimeDelta::seconds(60));
    auto.write_state(&State {
        last_switch: None,
        retry_at: Some(now),
    });

    assert_eq!(
        auto.retry(now),
        Outcome::Ignored("“work” has usage again, so it stays".into())
    );
    assert_eq!(auto.pending_retry(), None);
    assert_eq!(f.active().as_deref(), Some("work"));
}

#[test]
fn round_trip_real_config_copy() {
    let Some(path) = std::env::var_os("SWAPBOT_ROUNDTRIP") else {
        return;
    };
    let path = PathBuf::from(path);
    let canonical =
        || -> Value { serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap() };
    let before = canonical();
    let dir = path.parent().unwrap().to_path_buf();
    let paths = Paths {
        service: "unused".to_string(),
        profile_dir: dir.clone(),
        claude_json: path.clone(),
        claude_settings: dir.join("settings.json"),
        credentials_file: dir.join(".credentials.json"),
    };
    let store = Store::new(
        paths.clone(),
        Box::new(CredentialFiles::new(paths.credentials_file, dir)),
    );
    store.update_claude_json(|_| {}).unwrap();
    assert_eq!(canonical(), before);
}

#[cfg(target_os = "macos")]
#[test]
fn keychain_round_trips_large_blobs() {
    use crate::credentials::{Credentials, Keychain};
    let keychain = Keychain::new(format!("SwapBotTest-{}", Uuid::new_v4()));
    let slot = Slot::Saved("work".into());
    let big = format!(
        r#"{{"claudeAiOauth":{{"accessToken":"{}","note":"ünïcödé"}}}}"#,
        "x".repeat(20_000)
    );
    keychain.write(&slot, &big).unwrap();
    let read = keychain.read(&slot);
    keychain.delete(&slot).unwrap();
    assert_eq!(read.unwrap().as_deref(), Some(big.as_str()));
    assert_eq!(keychain.read(&slot).unwrap(), None);
}
