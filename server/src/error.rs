use axum::{
    http::StatusCode,
    response::{IntoResponse, Response},
};

#[derive(Debug, thiserror::Error)]
pub(crate) enum AppError {
    #[error("{0}")]
    Invalid(&'static str),
    #[error("{0} not found")]
    NotFound(&'static str),
    #[error("database unavailable")]
    Database(sqlx::Error),
}

/// SQLite reports constraint failures as extended result codes; depending on the build the
/// primary code (`19`) may come back instead, so fall back to the message.
fn constraint_message(db: &dyn sqlx::error::DatabaseError) -> Option<&'static str> {
    match db.code().as_deref() {
        Some("787") => return Some("project does not exist"),
        Some("1555") | Some("2067") => return Some("that name is already taken"),
        _ => {}
    }

    let message = db.message();
    if message.contains("FOREIGN KEY") {
        Some("project does not exist")
    } else if message.contains("UNIQUE") {
        Some("that name is already taken")
    } else {
        None
    }
}

impl From<sqlx::Error> for AppError {
    fn from(error: sqlx::Error) -> Self {
        if let sqlx::Error::Database(db) = &error {
            if let Some(message) = constraint_message(db.as_ref()) {
                return Self::Invalid(message);
            }
        }
        Self::Database(error)
    }
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let status = match self {
            Self::Invalid(_) => StatusCode::BAD_REQUEST,
            Self::NotFound(_) => StatusCode::NOT_FOUND,
            Self::Database(_) => StatusCode::SERVICE_UNAVAILABLE,
        };
        (status, self.to_string()).into_response()
    }
}
