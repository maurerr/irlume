// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright the irlume contributors.

//! Attended T480 hardware authentication probe (ADR-0031/ADR-0032 candidate).
//!
//! The ignored test at the bottom is the only hardware-executing item here:
//! it sends one `Authenticate` request through the real socket to the
//! candidate daemon and passes only on a granted `AuthResult`. Everything else
//! in this file runs without hardware and pins the failure semantics the
//! attended run depends on.

#[cfg(test)]
mod t480_hw_authenticate_isolated {
    use irlume_common::{Request, Response};
    use std::path::{Path, PathBuf};

    /// The installed daemon's socket. The candidate must never be it.
    const INSTALLED_SOCKET: &str = "/run/irlume.sock";

    /// The lab socket path, with no fallback: unset `IRLUME_SOCKET` is a hard
    /// error, never a default that could silently address another daemon.
    ///
    /// # Panics
    ///
    /// Panics when `IRLUME_SOCKET` is unset or empty.
    fn required_socket() -> PathBuf {
        let path = std::env::var("IRLUME_SOCKET")
            .expect("IRLUME_SOCKET must be set to the candidate daemon socket");
        assert!(!path.is_empty(), "IRLUME_SOCKET must not be empty");
        PathBuf::from(path)
    }

    /// Refuse the installed socket and any mismatch between the required path
    /// and the path the client will actually dial.
    fn check_socket_path(required: &Path, actual: &Path) {
        assert_ne!(
            required,
            Path::new(INSTALLED_SOCKET),
            "the candidate must not be the installed daemon socket"
        );
        assert_eq!(
            actual, required,
            "the client would dial a different socket than required"
        );
    }

    /// Only a granted `AuthResult` passes. A refused `AuthResult`, any
    /// `Error`, and any other reply shape fail.
    fn require_granted(response: &Response) -> Result<(), String> {
        match response {
            Response::AuthResult { granted: true, .. } => Ok(()),
            Response::AuthResult {
                granted: false,
                reason,
                ..
            } => Err(format!("daemon refused authentication: {reason}")),
            Response::Error(error) => Err(format!("daemon answered Error: {error}")),
            other => Err(format!("unexpected reply shape: {other:?}")),
        }
    }

    fn granted_auth_result() -> Response {
        Response::AuthResult {
            granted: true,
            score: 0.99,
            live: true,
            reason: String::new(),
            refused_by_policy: false,
            declined_by_gesture: false,
            situation: String::new(),
            cause: None,
        }
    }

    fn refused_auth_result() -> Response {
        Response::AuthResult {
            granted: false,
            score: 0.1,
            live: false,
            reason: "no match".into(),
            refused_by_policy: false,
            declined_by_gesture: false,
            situation: "no match".into(),
            cause: None,
        }
    }

    #[test]
    fn granted_auth_result_passes_the_verdict() {
        require_granted(&granted_auth_result()).expect("a grant must pass");
    }

    #[test]
    fn refused_auth_result_fails_the_verdict() {
        let error = require_granted(&refused_auth_result()).expect_err("granted:false must fail");
        assert!(error.contains("refused"), "{error}");
    }

    #[test]
    fn error_reply_fails_the_verdict() {
        let error = require_granted(&Response::Error("camera unavailable".into()))
            .expect_err("Error must fail");
        assert!(error.contains("camera unavailable"), "{error}");
    }

    #[test]
    fn unexpected_reply_shape_fails_the_verdict() {
        let error = require_granted(&Response::Pong).expect_err("a non-auth reply must fail");
        assert!(error.contains("unexpected reply"), "{error}");
    }

    #[test]
    fn socket_check_rejects_the_installed_socket() {
        let installed = PathBuf::from(INSTALLED_SOCKET);
        let result = std::panic::catch_unwind(|| check_socket_path(&installed, &installed));
        assert!(result.is_err(), "the installed socket must be refused");
    }

    #[test]
    fn socket_check_rejects_a_client_path_mismatch() {
        let required = PathBuf::from("/tmp/irlume-t480-lab.xxxx/irlume.sock");
        let actual = PathBuf::from("/tmp/other.sock");
        let result = std::panic::catch_unwind(|| check_socket_path(&required, &actual));
        assert!(result.is_err(), "a dial-path mismatch must fail");
    }

    #[test]
    fn socket_check_accepts_a_matching_lab_path() {
        let required = PathBuf::from("/tmp/irlume-t480-lab.xxxx/irlume.sock");
        check_socket_path(&required, &required);
    }

    #[test]
    #[ignore = "requires physical T480 descriptor-attested IR hardware, physical presence, IRLUME_T480_TEST_USER and IRLUME_SOCKET"]
    fn t480_hw_authenticate_isolated() {
        let user = std::env::var("IRLUME_T480_TEST_USER")
            .expect("IRLUME_T480_TEST_USER must be set for this physical test");

        // No fallback: the required path comes only from the environment, and
        // the dialed path is read back from the same client resolution the
        // request below uses.
        let required = required_socket();
        let actual = irlume_common::client::socket_path();
        check_socket_path(&required, &actual);

        let request = Request::Authenticate {
            user,
            service: Some("t480-physical-test".into()),
            structured_errors: false,
            intent_confirmation: None,
        };

        // No assessment or capture fixture is installed anywhere on this path:
        // the request goes to the candidate daemon as-is.
        let response = irlume_common::client::request(&request).expect("send Authenticate request");

        // The reply is matched, never printed: scores, reasons and any
        // credential payload stay out of the test output.
        require_granted(&response).expect("attended T480 authentication must grant");
    }
}
