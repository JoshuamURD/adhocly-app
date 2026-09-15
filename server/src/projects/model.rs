use serde::{Deserialize, Serialize};
use sqlx::FromRow;
use utoipa::ToSchema;

use crate::error::AppError;

/// Seeded by migration 0002; the fallback home for tasks whose project is deleted.
pub(crate) const INBOX_ID: &str = "inbox";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, ToSchema)]
#[serde(rename_all = "lowercase")]
pub(crate) enum FieldKind {
    Text,
    Number,
    Choice,
}

impl FieldKind {
    pub(crate) fn parse(value: &str) -> Option<Self> {
        match value {
            "text" => Some(Self::Text),
            "number" => Some(Self::Number),
            "choice" => Some(Self::Choice),
            _ => None,
        }
    }

    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Text => "text",
            Self::Number => "number",
            Self::Choice => "choice",
        }
    }
}

#[derive(Debug, Serialize, ToSchema)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Project {
    pub(crate) id: String,
    pub(crate) name: String,
    pub(crate) created_at: String,
    pub(crate) updated_at: String,
    /// Loaded in a second query, never a column on `projects`.
    pub(crate) metadata: Vec<MetadataValue>,
}

impl Project {
    pub(crate) fn new(id: String, name: String, created_at: String, updated_at: String) -> Self {
        Self {
            id,
            name,
            created_at,
            updated_at,
            metadata: Vec::new(),
        }
    }
}

#[derive(Debug, Serialize, ToSchema, FromRow)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MetadataValue {
    pub(crate) field_id: String,
    pub(crate) value: String,
}

#[derive(Debug, Serialize, ToSchema)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MetadataField {
    pub(crate) id: String,
    pub(crate) name: String,
    pub(crate) kind: FieldKind,
    pub(crate) options: Vec<String>,
    pub(crate) created_at: String,
}

#[derive(Debug, Deserialize, ToSchema)]
pub(crate) struct ProjectInput {
    pub(crate) name: String,
}

#[derive(Debug, Deserialize, ToSchema)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MetadataFieldInput {
    pub(crate) name: String,
    pub(crate) kind: FieldKind,
    #[serde(default)]
    pub(crate) options: Vec<String>,
}

#[derive(Debug, Deserialize, ToSchema)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MetadataFieldUpdate {
    pub(crate) name: String,
    #[serde(default)]
    pub(crate) options: Vec<String>,
}

#[derive(Debug, Deserialize, ToSchema)]
pub(crate) struct MetadataValueInput {
    /// Omit or send null/blank to clear the value.
    pub(crate) value: Option<String>,
}

pub(crate) fn encode_options(options: &[String]) -> String {
    options.join("\n")
}

/// Choice fields keep their option list; every other kind stores none.
pub(crate) fn normalize_options(
    kind: FieldKind,
    options: Vec<String>,
) -> Result<Vec<String>, AppError> {
    if kind != FieldKind::Choice {
        return Ok(Vec::new());
    }

    let mut unique: Vec<String> = Vec::new();
    for option in options {
        let option = option.trim();
        if !option.is_empty() && !unique.iter().any(|existing| existing == option) {
            unique.push(option.to_owned());
        }
    }
    if unique.is_empty() {
        return Err(AppError::Invalid("choice fields need at least one option"));
    }
    Ok(unique)
}

pub(crate) fn validate_value(
    kind: FieldKind,
    options: &[String],
    value: &str,
) -> Result<(), AppError> {
    match kind {
        FieldKind::Text => Ok(()),
        FieldKind::Number => {
            if value.parse::<f64>().is_ok_and(f64::is_finite) {
                Ok(())
            } else {
                Err(AppError::Invalid("value must be a number"))
            }
        }
        FieldKind::Choice => {
            if options.iter().any(|option| option.as_str() == value) {
                Ok(())
            } else {
                Err(AppError::Invalid("value must be one of the field options"))
            }
        }
    }
}
