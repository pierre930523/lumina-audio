use thiserror::Error;

pub type Result<T, E = DbError> = std::result::Result<T, E>;

#[derive(Debug, Error)]
pub enum DbError {
    #[error("Database error: {0}")]
    Sqlx(#[from] sqlx::Error),

    #[error("Migration error: {0}")]
    Migrate(#[from] sqlx::migrate::MigrateError),

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Profile error: {0}")]
    Profile(#[from] ProfileError),

    #[error("Credential error: {0}")]
    Credential(#[from] crate::credential::CredentialError),

    #[error("Entity not found: {0}")]
    NotFound(String),

    #[error("Constraint violation: {0}")]
    ConstraintViolation(String),
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum ProfileError {
    #[error("Cannot delete default profile (id: '{0}')")]
    CannotDeleteDefault(String),

    #[error("Cannot delete the last remaining profile")]
    CannotDeleteLastProfile,

    #[error(
        "Cannot unset default on the only default profile (designate another default profile first)"
    )]
    CannotUnsetDefaultProfile,

    #[error("Profile not found: '{0}'")]
    NotFound(String),
}
