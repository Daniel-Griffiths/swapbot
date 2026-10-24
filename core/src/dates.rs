use chrono::{DateTime, Utc};
use serde::{de, Deserialize, Deserializer, Serializer};

pub fn format(date: &DateTime<Utc>) -> String {
    date.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

pub fn parse(text: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(text)
        .ok()
        .map(|date| date.with_timezone(&Utc))
}

pub fn from_millis(ms: f64) -> Option<DateTime<Utc>> {
    if ms > 0.0 {
        DateTime::from_timestamp_millis(ms as i64)
    } else {
        None
    }
}

pub fn serialize<S: Serializer>(date: &DateTime<Utc>, serializer: S) -> Result<S::Ok, S::Error> {
    serializer.serialize_str(&format(date))
}

pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<DateTime<Utc>, D::Error> {
    let text = String::deserialize(deserializer)?;
    parse(&text).ok_or_else(|| de::Error::custom(format!("invalid date “{text}”")))
}

pub mod option {
    use chrono::{DateTime, Utc};
    use serde::{de, Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(
        date: &Option<DateTime<Utc>>,
        serializer: S,
    ) -> Result<S::Ok, S::Error> {
        match date {
            Some(date) => super::serialize(date, serializer),
            None => serializer.serialize_none(),
        }
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(
        deserializer: D,
    ) -> Result<Option<DateTime<Utc>>, D::Error> {
        Option::<String>::deserialize(deserializer)?
            .map(|text| {
                super::parse(&text)
                    .ok_or_else(|| de::Error::custom(format!("invalid date “{text}”")))
            })
            .transpose()
    }
}
