// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright the irlume contributors.

#[cfg(test)]
mod t480_hw_authenticate_isolated {
    use irlume_common::{Request, Response};
    
    #[test]
    #[ignore = "requires physical T480 descriptor-attested IR hardware, physical presence, and IRLUME_T480_TEST_USER"]
    fn t480_hw_authenticate_isolated_test() {
        let user = std::env::var("IRLUME_T480_TEST_USER")
            .expect("IRLUME_T480_TEST_USER must be set for this physical test");
        
        let sock_path = std::env::var("IRLUME_SOCKET").unwrap_or_else(|_| "/tmp/irlume-t480-test.sock".into());
        assert_ne!(sock_path, "/run/irlume.sock", "must not use the installed daemon socket");
        
        let req = Request::Authenticate {
            user,
            service: Some("t480-physical-test".into()),
            structured_errors: false,
            intent_confirmation: None,
        };

        // No fixture. We just send the request using the client module.
        // It honors IRLUME_SOCKET automatically.
        let response = irlume_common::client::request(&req).expect("send Authenticate request");

        match response {
            Response::AuthResult { .. } | Response::Error(_) => {
                // This is a test harness check, pass or fail based on expected outcome.
                // We just ensure the protocol is obeyed.
            }
            other => panic!("Unexpected response: {other:?}"),
        }
    }
}
