use std::collections::{BTreeMap, BTreeSet};

use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use sqlx::SqliteConnection;
use utoipa::ToSchema;

use crate::{error::AppError, state::AppState, sync::Write};

#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, ToSchema)]
#[serde(rename_all = "lowercase")]
pub(crate) enum ContextFieldKind {
    Identifier,
    Contact,
    Choice,
    Text,
    Date,
    Link,
    Note,
}

#[derive(Clone, Debug, Deserialize, Serialize, ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct ContextField {
    pub id: String,
    pub name: String,
    pub kind: ContextFieldKind,
    #[serde(default)]
    pub options: Vec<String>,
    #[serde(default)]
    pub value: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct WorkContext {
    pub id: String,
    pub name: String,
    pub fields: Vec<ContextField>,
}

#[derive(Clone, Debug, Deserialize, Serialize, ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct Contact {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub email: String,
    #[serde(default)]
    pub phone: String,
    #[serde(default)]
    pub notes: String,
}

/// Each owner has one independently revised attachment record. Empty values mask inheritance;
/// absent keys inherit. Field ids are scoped to a context, so unrelated schemas never collide.
#[derive(Clone, Debug, Deserialize, Serialize, ToSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ContextLinks {
    pub id: String,
    pub context_ids: Vec<String>,
    pub overrides: BTreeMap<String, BTreeMap<String, String>>,
}

async fn list<T: DeserializeOwned>(
    conn: &mut SqliteConnection,
    query: &'static str,
) -> Result<Vec<T>, AppError> {
    let rows: Vec<String> = sqlx::query_scalar(query).fetch_all(conn).await?;
    rows.iter()
        .map(|row| serde_json::from_str(row).map_err(Into::into))
        .collect()
}
pub(crate) async fn contexts_in(conn: &mut SqliteConnection) -> Result<Vec<WorkContext>, AppError> {
    list(conn, "SELECT data FROM contexts ORDER BY id").await
}
pub(crate) async fn contacts_in(conn: &mut SqliteConnection) -> Result<Vec<Contact>, AppError> {
    list(conn, "SELECT data FROM contacts ORDER BY id").await
}
pub(crate) async fn links_in(conn: &mut SqliteConnection) -> Result<Vec<ContextLinks>, AppError> {
    list(conn, "SELECT data FROM context_links ORDER BY id").await
}

fn id(value: &str) -> Result<(), AppError> {
    if value.is_empty()
        || value.len() > 128
        || !value
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
    {
        return Err(AppError::Invalid("invalid context, contact or field id"));
    }
    Ok(())
}
fn name(value: &str) -> Result<(), AppError> {
    if value.trim().is_empty() || value.len() > 256 {
        return Err(AppError::Invalid(
            "a nonempty name of at most 256 bytes is required",
        ));
    }
    Ok(())
}

async fn validate_value(
    conn: &mut SqliteConnection,
    field: &ContextField,
    value: &str,
    contacts: &[Contact],
) -> Result<(), AppError> {
    if value.len() > 65_536 {
        return Err(AppError::Invalid("context values cannot exceed 64 KB"));
    }
    if value.is_empty() {
        return Ok(());
    }
    match field.kind {
        ContextFieldKind::Contact if !contacts.iter().any(|c| c.id == value) => {
            return Err(AppError::Invalid("choose an existing contact"))
        }
        ContextFieldKind::Choice if !field.options.iter().any(|o| o == value) => {
            return Err(AppError::Invalid("choose an available context option"))
        }
        ContextFieldKind::Date => {
            let normalized: Option<String> = sqlx::query_scalar("SELECT date(?, '+0 days')")
                .bind(value)
                .fetch_one(conn)
                .await?;
            if value.len() != 10 || normalized.as_deref() != Some(value) {
                return Err(AppError::Invalid(
                    "context dates must be valid YYYY-MM-DD dates",
                ));
            }
        }
        ContextFieldKind::Link => {
            let uri = value
                .parse::<axum::http::Uri>()
                .map_err(|_| AppError::Invalid("links must be absolute HTTP or HTTPS URLs"))?;
            if !matches!(uri.scheme_str(), Some("http" | "https"))
                || uri.host().is_none_or(str::is_empty)
            {
                return Err(AppError::Invalid(
                    "links must be absolute HTTP or HTTPS URLs",
                ));
            }
        }
        _ => {}
    }
    Ok(())
}

async fn validate_overrides(
    conn: &mut SqliteConnection,
    context: &WorkContext,
    values: &BTreeMap<String, String>,
    contacts: &[Contact],
) -> Result<(), AppError> {
    for (id, value) in values {
        let field = context
            .fields
            .iter()
            .find(|f| &f.id == id)
            .ok_or(AppError::Invalid(
                "remove local overrides before removing their field",
            ))?;
        validate_value(conn, field, value, contacts).await?;
    }
    Ok(())
}

#[utoipa::path(put, path = "/api/contexts/{id}", params(("id" = String, Path)), request_body = WorkContext, responses((status = 200, body = WorkContext)), tag = "contexts")]
pub(crate) async fn save_context(
    Path(path): Path<String>,
    State(state): State<AppState>,
    Json(mut context): Json<WorkContext>,
) -> Result<Json<WorkContext>, AppError> {
    if path != context.id {
        return Err(AppError::Invalid("path and context ids must match"));
    }
    id(&context.id)?;
    context.name = context.name.trim().to_owned();
    name(&context.name)?;
    if context.fields.len() > 64 {
        return Err(AppError::Invalid("at most 64 fields per context"));
    }
    let mut write = Write::begin(state.pool(), state.sync.as_ref()).await?;
    if let Some(value) = write.replay()? {
        return Ok(Json(value));
    }
    let conn = &mut *write.transaction;
    let contacts = contacts_in(conn).await?;
    let previous = contexts_in(conn)
        .await?
        .into_iter()
        .find(|c| c.id == context.id);
    let mut ids = BTreeSet::new();
    let mut names = BTreeSet::new();
    for field in &mut context.fields {
        id(&field.id)?;
        field.name = field.name.trim().to_owned();
        name(&field.name)?;
        if !ids.insert(&field.id) || !names.insert(field.name.to_lowercase()) {
            return Err(AppError::Invalid(
                "context fields need unique ids and names",
            ));
        }
        if let Some(old) = previous
            .as_ref()
            .and_then(|c| c.fields.iter().find(|f| f.id == field.id))
        {
            if old.kind != field.kind {
                return Err(AppError::Invalid(
                    "a field's type cannot change; create a new field",
                ));
            }
        }
        if matches!(field.kind, ContextFieldKind::Choice) {
            let mut options = BTreeSet::new();
            if field.options.is_empty()
                || field.options.len() > 128
                || field.options.iter().any(|o| {
                    o.trim().is_empty() || o.len() > 256 || !options.insert(o.to_lowercase())
                })
            {
                return Err(AppError::Invalid(
                    "choice fields need 1–128 nonempty unique options",
                ));
            }
        } else if !field.options.is_empty() {
            return Err(AppError::Invalid("only choice fields have options"));
        }
        validate_value(conn, field, &field.value, &contacts).await?;
    }
    // Revalidate local overrides before a schema change, never silently discard them.
    for links in links_in(conn).await? {
        if let Some(values) = links.overrides.get(&context.id) {
            validate_overrides(conn, &context, values, &contacts).await?;
        }
    }
    sqlx::query("INSERT INTO contexts (id, data) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET data = excluded.data")
        .bind(&context.id).bind(serde_json::to_string(&context)?).execute(conn).await?;
    Ok(Json(write.commit(context).await?))
}

#[utoipa::path(put, path = "/api/contacts/{id}", params(("id" = String, Path)), request_body = Contact, responses((status = 200, body = Contact)), tag = "contexts")]
pub(crate) async fn save_contact(
    Path(path): Path<String>,
    State(state): State<AppState>,
    Json(mut contact): Json<Contact>,
) -> Result<Json<Contact>, AppError> {
    if path != contact.id {
        return Err(AppError::Invalid("path and contact ids must match"));
    }
    id(&contact.id)?;
    contact.name = contact.name.trim().to_owned();
    name(&contact.name)?;
    if contact.email.len() > 320 || contact.phone.len() > 128 || contact.notes.len() > 65_536 {
        return Err(AppError::Invalid("contact details are too long"));
    }
    let mut write = Write::begin(state.pool(), state.sync.as_ref()).await?;
    if let Some(value) = write.replay()? {
        return Ok(Json(value));
    }
    sqlx::query("INSERT INTO contacts (id, data) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET data = excluded.data")
        .bind(&contact.id).bind(serde_json::to_string(&contact)?).execute(&mut *write.transaction).await?;
    Ok(Json(write.commit(contact).await?))
}

#[utoipa::path(put, path = "/api/context-links/{id}", params(("id" = String, Path)), request_body = ContextLinks, responses((status = 200, body = ContextLinks)), tag = "contexts")]
pub(crate) async fn save_links(
    Path(path): Path<String>,
    State(state): State<AppState>,
    Json(links): Json<ContextLinks>,
) -> Result<Json<ContextLinks>, AppError> {
    if path != links.id {
        return Err(AppError::Invalid("path and attachment ids must match"));
    }
    let (kind, owner) = links.id.split_once(':').ok_or(AppError::Invalid(
        "attachment id must be tasks:id, projects:id or folders:id",
    ))?;
    if !["tasks", "projects", "folders"].contains(&kind) || owner.is_empty() {
        return Err(AppError::Invalid("invalid context owner"));
    }
    if links.context_ids.len() > 64 || links.overrides.len() > 64 {
        return Err(AppError::Invalid("at most 64 contexts per attachment"));
    }
    let mut write = Write::begin(state.pool(), state.sync.as_ref()).await?;
    if let Some(value) = write.replay()? {
        return Ok(Json(value));
    }
    let conn = &mut *write.transaction;
    let exists: bool = sqlx::query_scalar(match kind {
        "tasks" => "SELECT EXISTS(SELECT 1 FROM tasks WHERE id = ?)",
        "projects" => "SELECT EXISTS(SELECT 1 FROM projects WHERE id = ?)",
        _ => "SELECT EXISTS(SELECT 1 FROM folders WHERE id = ?)",
    })
    .bind(owner)
    .fetch_one(&mut *conn)
    .await?;
    if !exists {
        return Err(AppError::NotFound("context owner"));
    }
    let contexts = contexts_in(conn).await?;
    let contacts = contacts_in(conn).await?;
    let mut ids = BTreeSet::new();
    for id in &links.context_ids {
        if !ids.insert(id) || !contexts.iter().any(|c| &c.id == id) {
            return Err(AppError::Invalid("choose unique existing contexts"));
        }
    }
    // Overrides may be dormant after a move or detach. Retaining them avoids data loss and they
    // become effective again only when the context is attached somewhere in the new ancestry.
    for (id, values) in &links.overrides {
        let context = contexts
            .iter()
            .find(|c| &c.id == id)
            .ok_or(AppError::Invalid("unknown override context"))?;
        validate_overrides(conn, context, values, &contacts).await?;
    }
    sqlx::query("INSERT INTO context_links (id, data, task_id, project_id, folder_id) VALUES (?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET data = excluded.data")
        .bind(&links.id).bind(serde_json::to_string(&links)?)
        .bind((kind == "tasks").then_some(owner)).bind((kind == "projects").then_some(owner)).bind((kind == "folders").then_some(owner))
        .execute(conn).await?;
    Ok(Json(write.commit(links).await?))
}

#[utoipa::path(delete, path = "/api/contexts/{id}", params(("id" = String, Path)), responses((status = 204)), tag = "contexts")]
pub(crate) async fn delete_context(
    Path(id): Path<String>,
    State(state): State<AppState>,
) -> Result<StatusCode, AppError> {
    let mut write = Write::begin(state.pool(), state.sync.as_ref()).await?;
    if write.replay::<()>()?.is_some() {
        return Ok(StatusCode::NO_CONTENT);
    }
    let conn = &mut *write.transaction;
    if links_in(conn)
        .await?
        .iter()
        .any(|l| l.context_ids.contains(&id) || l.overrides.contains_key(&id))
    {
        return Err(AppError::Invalid(
            "detach this context and remove its overrides before deleting it",
        ));
    }
    if sqlx::query("DELETE FROM contexts WHERE id = ?")
        .bind(id)
        .execute(conn)
        .await?
        .rows_affected()
        == 0
    {
        return Err(AppError::NotFound("context"));
    }
    write.commit(()).await?;
    Ok(StatusCode::NO_CONTENT)
}

#[utoipa::path(delete, path = "/api/contacts/{id}", params(("id" = String, Path)), responses((status = 204)), tag = "contexts")]
pub(crate) async fn delete_contact(
    Path(id): Path<String>,
    State(state): State<AppState>,
) -> Result<StatusCode, AppError> {
    let mut write = Write::begin(state.pool(), state.sync.as_ref()).await?;
    if write.replay::<()>()?.is_some() {
        return Ok(StatusCode::NO_CONTENT);
    }
    let conn = &mut *write.transaction;
    let links = links_in(conn).await?;
    for context in contexts_in(conn).await? {
        for field in context
            .fields
            .iter()
            .filter(|f| matches!(f.kind, ContextFieldKind::Contact))
        {
            if field.value == id
                || links.iter().any(|l| {
                    l.overrides.get(&context.id).and_then(|v| v.get(&field.id)) == Some(&id)
                })
            {
                return Err(AppError::Invalid(
                    "remove this contact from contexts and overrides before deleting it",
                ));
            }
        }
    }
    if sqlx::query("DELETE FROM contacts WHERE id = ?")
        .bind(id)
        .execute(conn)
        .await?
        .rows_affected()
        == 0
    {
        return Err(AppError::NotFound("contact"));
    }
    write.commit(()).await?;
    Ok(StatusCode::NO_CONTENT)
}
