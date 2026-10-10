use std::path::PathBuf;
use tempfile::TempDir;

use ox_ipc::{serve, Client, Envelope};

fn echo(req: &mut Envelope) -> Envelope {
    req.ok(serde_json::json!({ "echoed": req.payload.clone() }))
}

#[test]
fn codec_roundtrip_preserves_fields() {
    let e = Envelope::request("op.x", 7, serde_json::json!({ "a": [1, 2] }));
    let bytes = e.encode().unwrap();
    assert_eq!(bytes.len(), 4 + (bytes.len() - 4) as usize);
    let back = Envelope::decode(&bytes[4..]).unwrap();
    assert_eq!(back, e);
}

#[test]
fn oversized_frame_is_rejected() {
    let too_big = (ox_ipc::MAX_FRAME + 1).to_le_bytes();
    let raw: Vec<u8> = too_big.to_vec();
    let mut r = ox_ipc::FrameReader::new(&raw[..]);
    let err = r.next_frame().unwrap_err();
    assert_eq!(err.kind(), std::io::ErrorKind::InvalidData);
}

#[test]
fn zero_length_frame_is_rejected() {
    let raw = [0u8; 8];
    let mut r = ox_ipc::FrameReader::new(&raw[..]);
    let err = r.next_frame().unwrap_err();
    assert_eq!(err.kind(), std::io::ErrorKind::InvalidData);
}

#[test]
fn eof_returns_none() {
    let empty: &[u8] = &[];
    let mut r = ox_ipc::FrameReader::new(empty);
    assert!(r.next_frame().unwrap().is_none());
}

#[test]
fn server_echoes_concurrent_clients() {
    let dir = TempDir::new().unwrap();
    let sock: PathBuf = dir.path().join("test.sock");
    let h = serve(&sock, echo).unwrap();

    let sock2 = sock.clone();
    let t1 = std::thread::spawn(move || {
        let mut c = Client::connect(&sock2).unwrap();
        for i in 0..20 {
            let r = c.request("ping", serde_json::json!({ "i": i })).unwrap();
            assert!(r.error.is_none());
        }
    });
    let sock3 = sock.clone();
    let t2 = std::thread::spawn(move || {
        let mut c = Client::connect(&sock3).unwrap();
        let r = c.request("status", serde_json::json!(null)).unwrap();
        assert_eq!(r.op, "status");
    });
    t1.join().unwrap();
    t2.join().unwrap();
    h.stop().unwrap();
    assert!(!sock.exists(), "socket file must be removed on shutdown");
}

#[test]
fn handler_error_path_roundtrips() {
    let dir = TempDir::new().unwrap();
    let sock: PathBuf = dir.path().join("err.sock");
    let h = serve(&sock, |req| req.err("nope")).unwrap();
    let mut c = Client::connect(&sock).unwrap();
    let r = c.request("boom", serde_json::json!(null)).unwrap();
    assert_eq!(r.error.as_deref(), Some("nope"));
    assert_eq!(r.id, Some(1));
    h.stop().unwrap();
}

#[test]
fn connect_to_missing_socket_fails() {
    let dir = TempDir::new().unwrap();
    assert!(Client::connect(dir.path().join("absent.sock")).is_err());
}

#[test]
fn stale_socket_file_is_replaced() {
    let dir = TempDir::new().unwrap();
    let sock: PathBuf = dir.path().join("stale.sock");
    std::fs::write(&sock, b"garbage").unwrap();
    let h = serve(&sock, echo).unwrap();
    let mut c = Client::connect(&sock).unwrap();
    assert!(c.request("x", serde_json::json!(null)).is_ok());
    h.stop().unwrap();
}
