use ox_ipc::{serve, Client, Envelope};
use ox_pay_proto::apdu::{Capdu, Rapdu};
use ox_pay_proto::emv::{AidEntry, HceKernel, PaymentSink};
use ox_pay_proto::ndef;
use serde_json::json;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct TxId(pub u64);

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TxStatus {
    Pending,
    Authorized,
    Cancelled,
}

#[derive(Debug, PartialEq, Eq)]
pub enum TxError {
    UnknownTx,
    AlreadyResolved,
    InvalidAmount,
}

pub trait PaymentTerminal {
    fn begin(&mut self, amount_minor: u64, currency: &str) -> Result<TxId, TxError>;
    fn confirm(&mut self, tx: TxId) -> Result<TxStatus, TxError>;
    fn cancel(&mut self, tx: TxId) -> Result<TxStatus, TxError>;
    fn status_of(&self, tx: TxId) -> Option<TxStatus>;
}

pub struct MemoryTerminal {
    next: u64,
    txs: HashMap<TxId, TxStatus>,
}

impl MemoryTerminal {
    pub fn new() -> Self {
        MemoryTerminal { next: 1, txs: HashMap::new() }
    }
}

impl Default for MemoryTerminal {
    fn default() -> Self {
        Self::new()
    }
}

impl PaymentTerminal for MemoryTerminal {
    fn begin(&mut self, amount_minor: u64, _currency: &str) -> Result<TxId, TxError> {
        if amount_minor == 0 || amount_minor > 500_000_00 {
            return Err(TxError::InvalidAmount);
        }
        let id = TxId(self.next);
        self.next += 1;
        self.txs.insert(id, TxStatus::Pending);
        Ok(id)
    }

    fn confirm(&mut self, tx: TxId) -> Result<TxStatus, TxError> {
        match self.txs.get_mut(&tx) {
            None => Err(TxError::UnknownTx),
            Some(TxStatus::Pending) => {
                *self.txs.get_mut(&tx).unwrap() = TxStatus::Authorized;
                Ok(TxStatus::Authorized)
            }
            Some(_) => Err(TxError::AlreadyResolved),
        }
    }

    fn cancel(&mut self, tx: TxId) -> Result<TxStatus, TxError> {
        match self.txs.get_mut(&tx) {
            None => Err(TxError::UnknownTx),
            Some(s @ TxStatus::Pending) => {
                *s = TxStatus::Cancelled;
                Ok(TxStatus::Cancelled)
            }
            Some(_) => Err(TxError::AlreadyResolved),
        }
    }

    fn status_of(&self, tx: TxId) -> Option<TxStatus> {
        self.txs.get(&tx).cloned()
    }
}

fn status_word(s: &TxStatus) -> &'static str {
    match s {
        TxStatus::Pending => "pending",
        TxStatus::Authorized => "authorized",
        TxStatus::Cancelled => "cancelled",
    }
}

/// Adapts the in-memory terminal to the HCE kernel's PaymentSink seam:
/// approve = begin+confirm on the terminal ledger, decline = begin+cancel.
struct TerminalSink<'a>(&'a mut dyn PaymentTerminal);

impl PaymentSink for TerminalSink<'_> {
    fn approve(&mut self, amount_minor: u64, currency: &str) -> Result<u64, String> {
        let id = self
            .0
            .begin(amount_minor, currency)
            .map_err(|e| format!("{e:?}"))?;
        match self.0.confirm(id) {
            Ok(_) => Ok(id.0),
            Err(e) => Err(format!("{e:?}")),
        }
    }

    fn decline(&mut self, amount_minor: u64, currency: &str) -> Result<u64, String> {
        let id = self
            .0
            .begin(amount_minor, currency)
            .map_err(|e| format!("{e:?}"))?;
        self.0.cancel(id).map_err(|e| format!("{e:?}"))?;
        Ok(id.0)
    }
}

fn demo_apps() -> Vec<AidEntry> {
    vec![AidEntry {
        aid: vec![0xF0, 0x4F, 0x58, 0x50, 0x41, 0x59], // F0-OxPAY demo AID
        label: "Ox Wallet".into(),
        priority: 0x01,
    }]
}

fn hex_decode(s: &str) -> Result<Vec<u8>, String> {
    let s = s.trim();
    if s.len() % 2 != 0 {
        return Err("hex: odd length".into());
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).map_err(|e| format!("hex: {e}")))
        .collect()
}

fn hex_encode(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02X}")).collect()
}

pub fn handle_request(
    t: &mut dyn PaymentTerminal,
    kernel: &mut HceKernel,
    req: &Envelope,
    ui: Option<Arc<Mutex<MemoryTerminal>>>,
) -> Envelope {
    match req.op.as_str() {
        "begin_tx" => match t.begin(
            req.payload.as_ref().and_then(|p| p["amount_minor"].as_u64()).unwrap_or(0),
            "eur",
        ) {
            Ok(id) => req.ok(json!({ "tx": id.0 })),
            Err(TxError::InvalidAmount) => req.err("invalid amount"),
            Err(_) => req.err("begin failed"),
        },
        "confirm_tx" => {
            let id = req.payload.as_ref().and_then(|p| p["tx"].as_u64());
            match id.map(TxId) {
                Some(id) => match t.confirm(id) {
                    Ok(s) => req.ok(json!({ "status": status_word(&s) })),
                    Err(TxError::UnknownTx) => req.err("unknown tx"),
                    Err(TxError::AlreadyResolved) => req.err("already resolved"),
                    Err(_) => req.err("confirm failed"),
                },
                None => req.err("missing tx"),
            }
        }
        "cancel_tx" => {
            let id = req.payload.as_ref().and_then(|p| p["tx"].as_u64());
            match id.map(TxId) {
                Some(id) => match t.cancel(id) {
                    Ok(s) => req.ok(json!({ "status": status_word(&s) })),
                    Err(_) => req.err("cancel failed"),
                },
                None => req.err("missing tx"),
            }
        }
        "hce-apdu" => {
            // One contactless presentation = the kernel's session; readers
            // send SELECT PPSE first, then AID, then the Ox authorize round.
            let hex_str = req.payload.as_ref().and_then(|p| p["hex"].as_str()).unwrap_or("");
            let resp = (|| -> Result<Rapdu, String> {
                let raw = hex_decode(hex_str)?;
                let capdu = Capdu::parse(&raw)?;
                let mut sink = TerminalSink(t);
                Ok(kernel.process(&capdu, &mut sink))
            })();
            match resp {
                Ok(r) => req.ok(json!({
                    "rapdu": hex_encode(&r.encode()),
                    "sw": format!("{:04X}", r.sw),
                })),
                Err(e) => req.err(&e),
            }
        }
        "handoff-build" => {
            // Peer/merchant side: encode a payment request into a Type-2
            // tag image (Text + `oxpay://` URI records, TLV-wrapped).
            let p = match req.payload.as_ref() {
                Some(p) => p,
                None => return req.err("missing payload"),
            };
            let r = ndef::PaymentRequest {
                amount_minor: p["amount_minor"].as_u64().unwrap_or(0),
                merchant: p["merchant"].as_str().unwrap_or("").into(),
                reference: p["ref"].as_str().map(|s| s.to_string()),
            };
            match ndef::build_handoff_tag(&r) {
                Ok(tag) => req.ok(json!({
                    "tag_hex": hex_encode(&tag),
                    "uri": ndef::payment_request_uri(&r).unwrap_or_default(),
                })),
                Err(e) => req.err(&e),
            }
        }
        "list_receipts" => req.ok(json!({ "receipts": read_receipts() })),
        "handoff-read" => {
            // Reader side: a tapped tag image becomes a validated request.
            let hex_str =
                req.payload.as_ref().and_then(|p| p["tag_hex"].as_str()).unwrap_or("");
            match hex_decode(hex_str).and_then(|raw| ndef::read_handoff_tag(&raw)) {
                Ok(r) => {
                    // A real tap means the user must confirm: pop the
                    // confirmation card on the compositor (dev/demo builds
                    // pass the UI context; bare test harnesses pass None).
                    if let Some(term) = ui {
                        let req = r.clone();
                        std::thread::spawn(move || confirm_ui(term, req));
                    }
                    req.ok(json!({
                        "amount_minor": r.amount_minor,
                        "merchant": r.merchant,
                        "ref": r.reference,
                    }))
                }
                Err(e) => req.err(&e),
            }
        }
        "status" => req.ok(json!({
            "service": "oxpaymentsd",
            "backend": "memory",
            "hce": "ox-pay-proto kernel",
            "simulated_cryptography": ox_pay_proto::emv::SIMULATED_CRYPTOGRAPHY,
        })),
        _ => req.err("unknown op"),
    }
}

/// Draw ops for the confirmation card. Pure so the layout is testable.
fn confirm_ops(state: &str, r: &ndef::PaymentRequest, w: u32, h: u32) -> serde_json::Value {
    let bar_h = 28u64;
    let pad = 14u64;
    let major = r.amount_minor / 100;
    let minor = r.amount_minor % 100;
    let amount = format!("{}.{:02} EUR", major, minor);
    let mut ops = vec![
        json!({"t": "rect", "x": 0, "y": 0, "w": w, "h": h, "rgb": 0x10202E}),
        json!({"t": "rect", "x": 0, "y": 0, "w": w, "h": bar_h, "rgb": 0x14324A}),
        json!({"t": "text", "x": pad, "y": 8, "rgb": 0x9FE8FF,
               "s": "Ox payment request", "scale": 2}),
        json!({"t": "text", "x": pad, "y": bar_h + 10, "rgb": 0xE8F2FA,
               "s": &format!("to: {}", r.merchant), "scale": 2}),
        json!({"t": "text", "x": pad, "y": bar_h + 32, "rgb": 0xE8F2FA,
               "s": &format!("amount: {}", amount), "scale": 2}),
    ];
    if let Some(t) = &r.reference {
        ops.push(json!({"t": "text", "x": pad, "y": bar_h + 54, "rgb": 0x6B7A8C,
                        "s": &format!("ref: {}", t), "scale": 2}));
    }
    let prompt = match state {
        "ask" => "A=accept   R=reject",
        other => other,
    };
    ops.push(json!({"t": "text", "x": pad, "y": h as u64 - 24, "rgb": 0x7CE38B,
                    "s": prompt, "scale": 2}));
    json!({ "ops": ops })
}

fn connect_retry(sock: &PathBuf) -> Option<Client> {
    for _ in 0..50 {
        if let Ok(c) = Client::connect(sock) {
            return Some(c);
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    None
}

/// Holds a powerd wake lock for the lifetime of a confirmation card: a
/// payment decision must not be interrupted by idle doze (dropped on every
/// exit path, including timeouts).
struct WakeGuard {
    pwr: Option<Client>,
    id: String,
}
impl Drop for WakeGuard {
    fn drop(&mut self) {
        if let Some(p) = self.pwr.as_mut() {
            let _ = p.request("wake-lock", json!({ "id": self.id, "release": true }));
        }
    }
}

fn confirm_wake_lock() -> WakeGuard {
    let id = format!("paymentsd-confirm-{}", std::process::id());
    let sock = std::env::var_os("OX_SOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
        .join("powerd.sock");
    let mut pwr = connect_retry(&sock);
    match pwr.as_mut() {
        Some(p) => {
            let _ = p.request("wake-lock", json!({ "id": id }));
        }
        None => {
            eprintln!("paymentsd: powerd unreachable — confirm runs without wake lock");
        }
    }
    WakeGuard { pwr, id }
}

/// The wallet-side confirmation flow: a card on the compositor, keys from
/// the compositor (apps never touch input devices), authorize/reject on the
/// ledger. Parks after resolution so the card stays visible for the gate.
fn confirm_ui(term: Arc<Mutex<MemoryTerminal>>, r: ndef::PaymentRequest) {
    let sock = std::env::var_os("OX_SOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
        .join("oxcom.sock");
    let Some(mut cl) = connect_retry(&sock) else {
        eprintln!("paymentsd: no compositor — confirmation unavailable");
        return;
    };
    let wake = confirm_wake_lock();
    let st = match cl.request("status", json!(null)) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("paymentsd: compositor status failed: {e}");
            return;
        }
    };
    let (w, h) = st
        .payload
        .as_ref()
        .map(|p| {
            (
                p.get("w").and_then(|v| v.as_u64()).unwrap_or(0),
                p.get("h").and_then(|v| v.as_u64()).unwrap_or(0),
            )
        })
        .unwrap_or((0, 0));
    if w == 0 || h == 0 {
        eprintln!("paymentsd: compositor has no display — confirmation unavailable");
        return;
    }

    let (win_w, win_h) = (360u64, 140u64);
    let win_x = (w - win_w) / 2;
    let win_y = (h - win_h) / 2;
    let resp = match cl.request("window-new", json!({"x": win_x, "y": win_y, "w": win_w, "h": win_h})) {
        Ok(x) => x,
        Err(e) => {
            eprintln!("paymentsd: window-new failed: {e}");
            return;
        }
    };
    let Some(win_id) = resp.payload.as_ref().and_then(|p| p.get("id")).and_then(|v| v.as_u64())
    else {
        eprintln!("paymentsd: window-new: no id");
        return;
    };
    let _ = cl.request("window-focus", json!({ "id": win_id }));

    let commit = |cl: &mut Client, state: &str| {
        let payload = confirm_ops(state, &r, win_w as u32, win_h as u32);
        if let Err(e) = cl.request("window-commit", json!({"id": win_id, "ops": payload["ops"]})) {
            eprintln!("paymentsd: window-commit failed: {e}");
        }
    };
    commit(&mut cl, "ask");
    eprintln!(
        "OXMILESTONE name=payment-confirm-shown amount={} merchant={}",
        r.amount_minor, r.merchant
    );

    loop {
        let resp = match cl.request("key-recv", json!({ "window": win_id, "timeout_ms": 60000 })) {
            Ok(x) => x,
            Err(_) => return,
        };
        let Some(ev) = resp.payload.as_ref().and_then(|p| p.get("event")).filter(|e| !e.is_null()).cloned() else {
            commit(&mut cl, "ask (timed out)");
            eprintln!("OXMILESTONE name=payment-confirm-timeout");
            return;
        };
        let ch = ev.get("ch").and_then(|v| v.as_str()).unwrap_or("").to_string();
        let mut t = term.lock().unwrap();
        let resolved = match ch.as_str() {
            "a" | "A" => {
                let outcome = t
                    .begin(r.amount_minor, "eur")
                    .and_then(|tx| t.confirm(tx));
                match outcome {
                    Ok(_) => {
                        eprintln!(
                            "OXMILESTONE name=payment-authorized amount={} merchant={}",
                            r.amount_minor, r.merchant
                        );
                        match record_receipt(&r) {
                            Ok(path) => {
                                eprintln!(
                                    "OXMILESTONE name=receipt-recorded file={}",
                                    path.display()
                                );
                            }
                            Err(e) => eprintln!("paymentsd: receipt write failed: {e}"),
                        }
                        "AUTHORIZED"
                    }
                    Err(_) => {
                        eprintln!("paymentsd: authorize failed");
                        "AUTH FAILED"
                    }
                }
            }
            "r" | "R" => {
                let outcome = t
                    .begin(r.amount_minor, "eur")
                    .and_then(|tx| t.cancel(tx));
                match outcome {
                    Ok(_) => {
                        eprintln!("OXMILESTONE name=payment-rejected");
                        "REJECTED"
                    }
                    Err(_) => {
                        eprintln!("paymentsd: reject failed");
                        "REJECT FAILED"
                    }
                }
            }
            _ => continue,
        };
        commit(&mut cl, resolved);
        return; // card stays up; one decision per tap
    }
}

fn default_socket() -> PathBuf {
    std::env::var_os("OX_SOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/ox/sockets"))
        .join("paymentsd.sock")
}

/// Dev/demo receipt store: one JSON line per authorized payment, on the
/// persistent data volume (/data is the LUKS store mounted by stage 2).
fn data_dir() -> PathBuf {
    PathBuf::from(std::env::var("OX_DATA_DIR").unwrap_or_else(|_| "/data/ox".into()))
}

fn record_receipt(r: &ndef::PaymentRequest) -> std::io::Result<PathBuf> {
    let dir = data_dir();
    std::fs::create_dir_all(&dir)?;
    let rec = json!({
        "ts": std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0),
        "amount_minor": r.amount_minor,
        "merchant": r.merchant,
        "reference": r.reference,
    });
    let path = dir.join("receipts.jsonl");
    use std::io::Write as _;
    let mut f = std::fs::OpenOptions::new().create(true).append(true).open(&path)?;
    writeln!(f, "{rec}")?;
    // A payment record must survive power loss: flush through the ext4
    // journal instead of trusting the page-cache commit interval.
    f.sync_all()?;
    Ok(path)
}

fn read_receipts() -> Vec<serde_json::Value> {
    std::fs::read_to_string(data_dir().join("receipts.jsonl"))
        .map(|s| s.lines().filter_map(|l| serde_json::from_str(l).ok()).collect())
        .unwrap_or_default()
}

fn main() -> std::io::Result<()> {
    let sock = default_socket();
    eprintln!("oxpaymentsd: serving on {}", sock.display());
    let term = std::sync::Arc::new(std::sync::Mutex::new(MemoryTerminal::new()));
    // Dev-phase device key: derived, not hardcoded. Phase 6 moves key custody
    // into the eSE (SIMULATED_CRYPTOGRAPHY banner stays until then).
    let device_key =
        ox_pay_proto::hmac::hmac_sha256(b"ox-pay-proto dev key", b"oxpaymentsd");
    let kernel = std::sync::Arc::new(std::sync::Mutex::new(HceKernel::new(
        demo_apps(),
        "eur",
        device_key,
    )));
    let _handle = serve(&sock, move |req| {
        let mut g = term.lock().unwrap();
        let mut k = kernel.lock().unwrap();
        handle_request(&mut *g, &mut k, req, Some(Arc::clone(&term)))
    })?;
    loop {
        std::thread::sleep(std::time::Duration::from_secs(3600));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ox_ipc::Client;

    #[test]
    fn confirm_card_layout() {
        let r = ndef::PaymentRequest {
            amount_minor: 1250,
            merchant: "cafe.example".into(),
            reference: None,
        };
        let v = confirm_ops("ask", &r, 360, 140);
        let ops = v.get("ops").and_then(|o| o.as_array()).unwrap();
        assert!(ops.iter().any(|o| o["s"] == "amount: 12.50 EUR"));
        assert!(ops.iter().any(|o| o["s"] == "A=accept   R=reject"));
        let v2 = confirm_ops("AUTHORIZED", &r, 360, 140);
        let ops2 = v2.get("ops").and_then(|o| o.as_array()).unwrap();
        assert!(ops2.iter().any(|o| o["s"] == "AUTHORIZED"));
    }

    #[test]
    fn lifecycle_pending_to_authorized() {
        let mut t = MemoryTerminal::new();
        let id = t.begin(1500, "eur").unwrap();
        assert_eq!(t.status_of(id), Some(TxStatus::Pending));
        assert_eq!(t.confirm(id), Ok(TxStatus::Authorized));
        assert_eq!(t.confirm(id), Err(TxError::AlreadyResolved));
    }

    #[test]
    fn cancel_blocks_confirm() {
        let mut t = MemoryTerminal::new();
        let id = t.begin(100, "eur").unwrap();
        assert_eq!(t.cancel(id), Ok(TxStatus::Cancelled));
        assert_eq!(t.confirm(id), Err(TxError::AlreadyResolved));
    }

    #[test]
    fn amount_bounds_enforced() {
        let mut t = MemoryTerminal::new();
        assert_eq!(t.begin(0, "eur"), Err(TxError::InvalidAmount));
        assert_eq!(t.begin(10_000_000_00, "eur"), Err(TxError::InvalidAmount));
    }

    #[test]
    fn unknown_tx_errors() {
        let mut t = MemoryTerminal::new();
        assert_eq!(t.confirm(TxId(999)), Err(TxError::UnknownTx));
    }

    #[test]
    fn ipc_ops_drive_terminal_end_to_end() {
        use ox_ipc::serve;
        use std::path::PathBuf;
        let dir = std::env::temp_dir().join(format!("pay-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let sock: PathBuf = dir.join("p.sock");
        let term = std::sync::Arc::new(std::sync::Mutex::new(MemoryTerminal::new()));
        let kernel = std::sync::Arc::new(std::sync::Mutex::new(HceKernel::new(
            demo_apps(),
            "eur",
            [9u8; 32],
        )));
        let h = serve(&sock, move |req| {
            let mut g = term.lock().unwrap();
            let mut k = kernel.lock().unwrap();
            handle_request(&mut *g, &mut k, &req, None)
        })
        .unwrap();
        let mut c = Client::connect(&sock).unwrap();
        let r = c.request("begin_tx", json!({ "amount_minor": 2500 })).unwrap();
        assert!(r.error.is_none());
        let tx = r.payload.unwrap()["tx"].as_u64().unwrap();
        let r2 = c.request("confirm_tx", json!({ "tx": tx })).unwrap();
        assert_eq!(r2.payload.unwrap()["status"], "authorized");
        let r3 = c.request("confirm_tx", json!({ "tx": tx })).unwrap();
        assert_eq!(r3.error.as_deref(), Some("already resolved"));
        h.stop().unwrap();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn handoff_tap_to_authorize() {
        use ox_ipc::serve;
        use std::path::PathBuf;
        let dir = std::env::temp_dir().join(format!("pay-ho-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let sock: PathBuf = dir.join("p.sock");
        let term = std::sync::Arc::new(std::sync::Mutex::new(MemoryTerminal::new()));
        let kernel = std::sync::Arc::new(std::sync::Mutex::new(HceKernel::new(
            demo_apps(),
            "eur",
            [9u8; 32],
        )));
        let h = serve(&sock, move |req| {
            let mut g = term.lock().unwrap();
            let mut k = kernel.lock().unwrap();
            handle_request(&mut *g, &mut k, &req, None)
        })
        .unwrap();
        let mut c = Client::connect(&sock).unwrap();

        // Merchant side builds the tag; reader side taps it.
        let built = c
            .request(
                "handoff-build",
                json!({ "amount_minor": 1250, "merchant": "cafe.example",
                        "ref": "order-9" }),
            )
            .unwrap();
        assert!(built.error.is_none());
        let tag_hex =
            built.payload.as_ref().unwrap()["tag_hex"].as_str().unwrap().to_string();
        assert!(built.payload.as_ref().unwrap()["uri"]
            .as_str()
            .unwrap()
            .starts_with("oxpay://req?a=1250"));

        let read = c.request("handoff-read", json!({ "tag_hex": tag_hex })).unwrap();
        assert!(read.error.is_none());
        let p = read.payload.unwrap();
        assert_eq!(p["amount_minor"].as_u64(), Some(1250));
        assert_eq!(p["merchant"].as_str(), Some("cafe.example"));
        assert_eq!(p["ref"].as_str(), Some("order-9"));

        // The parsed request drives the real authorize path.
        let amount = p["amount_minor"].as_u64().unwrap();
        let r = c.request("begin_tx", json!({ "amount_minor": amount })).unwrap();
        let tx = r.payload.unwrap()["tx"].as_u64().unwrap();
        let r2 = c.request("confirm_tx", json!({ "tx": tx })).unwrap();
        assert_eq!(r2.payload.unwrap()["status"], "authorized");

        // Garbage tags are rejected, not guessed at.
        let bad = c.request("handoff-read", json!({ "tag_hex": "0102" })).unwrap();
        assert!(bad.error.is_some());

        h.stop().unwrap();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn hce_transaction_over_ipc() {
        use ox_ipc::serve;
        use std::path::PathBuf;
        let dir = std::env::temp_dir().join(format!("pay-hce-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let sock: PathBuf = dir.join("p.sock");
        let term = std::sync::Arc::new(std::sync::Mutex::new(MemoryTerminal::new()));
        let kernel = std::sync::Arc::new(std::sync::Mutex::new(HceKernel::new(
            demo_apps(),
            "eur",
            [7u8; 32],
        )));
        let h = serve(&sock, move |req| {
            let mut g = term.lock().unwrap();
            let mut k = kernel.lock().unwrap();
            handle_request(&mut *g, &mut k, &req, None)
        })
        .unwrap();
        let mut c = Client::connect(&sock).unwrap();

        let mut apdu = |hex: &str| c.request("hce-apdu", json!({ "hex": hex })).unwrap();

        // 1. SELECT PPSE "2PAY.SYS.DDF01"
        let r = apdu("00A404000E325041592E5359532E4444463031");
        let p = r.payload.unwrap();
        assert_eq!(p["sw"], "9000");
        let rapdu = p["rapdu"].as_str().unwrap();
        // FCI lists our AID
        assert!(rapdu.contains("4F06F04F58504159"));

        // 2. SELECT the Ox demo AID
        let r = apdu("00A4040006F04F58504159");
        assert_eq!(r.payload.unwrap()["sw"], "9000");

        // 3. AUTHORIZE 12.50 EUR -> 9000 with a 16-byte cryptogram
        let r = apdu("80520000099F0206303031323530");
        let p = r.payload.unwrap();
        assert_eq!(p["sw"], "9000");
        let rapdu = p["rapdu"].as_str().unwrap();
        assert!(rapdu.contains("9F26"), "cryptogram tag present: {rapdu}");

        // 4. unknown AID -> 6A82
        let r = apdu("00A4040005A000000003");
        assert_eq!(r.payload.unwrap()["sw"], "6A82");

        // 5. bad hex -> error
        assert!(apdu("XYZ").error.is_some());
        h.stop().unwrap();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn receipts_record_and_list() {
        let dir = std::env::temp_dir().join(format!("pay-receipts-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::env::set_var("OX_DATA_DIR", &dir);
        let r = ndef::PaymentRequest {
            amount_minor: 1250,
            merchant: "cafe.example".into(),
            reference: Some("order-9".into()),
        };
        let path = record_receipt(&r).unwrap();
        assert!(path.exists());
        let rs = read_receipts();
        assert_eq!(rs.len(), 1);
        assert_eq!(rs[0]["amount_minor"].as_u64(), Some(1250));
        assert_eq!(rs[0]["reference"].as_str(), Some("order-9"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
