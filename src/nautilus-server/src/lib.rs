// Copyright (c), Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::response::Response;
use axum::Json;
use fastcrypto::ed25519::Ed25519KeyPair;
use serde_json::json;
use std::fmt;

mod apps {
    #[path = "source-verification/mod.rs"]
    pub mod source_verification;
}

pub mod app {
    pub use crate::apps::source_verification::*;
}

pub mod common;

/// App state. This service holds only the ephemeral keypair generated on boot;
/// it takes no secrets, so there is nothing else to carry.
pub struct AppState {
    /// Ephemeral keypair on boot.
    pub eph_kp: Ed25519KeyPair,
}

/// Implement IntoResponse for EnclaveError.
impl IntoResponse for EnclaveError {
    fn into_response(self) -> Response {
        let (status, error_message) = match self {
            EnclaveError::GenericError(e) => (StatusCode::BAD_REQUEST, e),
        };
        let body = Json(json!({
            "error": error_message,
        }));
        (status, body).into_response()
    }
}

/// Enclave errors enum.
#[derive(Debug)]
pub enum EnclaveError {
    GenericError(String),
}

impl fmt::Display for EnclaveError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            EnclaveError::GenericError(e) => write!(f, "{e}"),
        }
    }
}

impl std::error::Error for EnclaveError {}
