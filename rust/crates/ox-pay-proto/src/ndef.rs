//! NDEF (NFC Forum Data Exchange Format): record build/parse with the
//! Text and URI record types, plus Type-2 tag TLV encapsulation. This is
//! the reader-mode/handoff message layer; HCE payment emulates cards, not
//! tags — NDEF travels over peer/tag interfaces.

/// One NDEF record.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Record {
    /// Type Name Format: 0x01 well-known, 0x02 MIME, 0x04 external...
    pub tnf: u8,
    pub r#type: Vec<u8>,
    pub id: Vec<u8>,
    pub payload: Vec<u8>,
}

pub const TNF_WELL_KNOWN: u8 = 0x01;

const HEADER_MB: u8 = 0x80;
const HEADER_ME: u8 = 0x40;
const HEADER_SR: u8 = 0x10;
const HEADER_IL: u8 = 0x08;

/// Build a message (multiple records with MB/ME flags set correctly).
pub fn build_message(records: &[Record]) -> Result<Vec<u8>, String> {
    if records.is_empty() {
        return Err("empty NDEF message".into());
    }
    let mut out = Vec::new();
    let last = records.len() - 1;
    for (i, r) in records.iter().enumerate() {
        if r.r#type.len() > 255 {
            return Err("type too long for short form".into());
        }
        if r.payload.len() > 255 {
            return Err("payload too long for short form".into());
        }
        let mut header = HEADER_SR;
        if i == 0 {
            header |= HEADER_MB;
        }
        if i == last {
            header |= HEADER_ME;
        }
        if !r.id.is_empty() {
            header |= HEADER_IL;
        }
        out.push(header);
        out.push(r.tnf);
        out.push(r.r#type.len() as u8);
        out.push(r.payload.len() as u8);
        if !r.id.is_empty() {
            out.push(r.id.len() as u8);
        }
        out.extend_from_slice(&r.r#type);
        out.extend_from_slice(&r.id);
        out.extend_from_slice(&r.payload);
    }
    Ok(out)
}

/// Parse a message of consecutive records.
pub fn parse_message(data: &[u8]) -> Result<Vec<Record>, String> {
    let mut out = Vec::new();
    let mut i = 0;
    loop {
        let header = *data.get(i).ok_or("truncated header")?;
        let sr = header & HEADER_SR != 0;
        let il = header & HEADER_IL != 0;
        if !sr {
            return Err("long-form records unsupported (keep payloads <=255B)".into());
        }
        let tnf = *data.get(i + 1).ok_or("truncated tnf")?;
        let tlen = *data.get(i + 2).ok_or("truncated type length")? as usize;
        let plen = *data.get(i + 3).ok_or("truncated payload length")? as usize;
        let mut j = i + 4;
        let ilen = if il {
            let l = *data.get(j).ok_or("truncated id length")? as usize;
            j += 1;
            l
        } else {
            0
        };
        let r#type = data.get(j..j + tlen).ok_or("type overrun")?.to_vec();
        j += tlen;
        let id = data.get(j..j + ilen).ok_or("id overrun")?.to_vec();
        j += ilen;
        let payload = data.get(j..j + plen).ok_or("payload overrun")?.to_vec();
        j += plen;
        let last = header & HEADER_ME != 0;
        out.push(Record { tnf, r#type, id, payload });
        if last {
            return Ok(out);
        }
        i = j;
    }
}

/// Well-known Text record (`T`): UTF-8, language code + text.
pub fn text_record(text: &str, lang: &str) -> Record {
    let mut payload = vec![lang.len() as u8];
    payload.extend_from_slice(lang.as_bytes());
    payload.extend_from_slice(text.as_bytes());
    Record {
        tnf: TNF_WELL_KNOWN,
        r#type: b"T".to_vec(),
        id: Vec::new(),
        payload,
    }
}

/// Well-known URI record (`U`): prefix-compressed.
pub fn uri_record(uri: &str) -> Record {
    const PREFIXES: [&str; 3] = ["https://www.", "http://www.", "https://"];
    let mut payload = Vec::new();
    let mut rest = uri;
    for (idx, p) in PREFIXES.iter().enumerate() {
        if let Some(stripped) = uri.strip_prefix(p) {
            payload.push(idx as u8 + 1); // prefix codes per NFC Forum URI record
            rest = stripped;
            break;
        }
    }
    if payload.is_empty() {
        payload.push(0u8); // no prefix
    }
    payload.extend_from_slice(rest.as_bytes());
    Record {
        tnf: TNF_WELL_KNOWN,
        r#type: b"U".to_vec(),
        id: Vec::new(),
        payload,
    }
}

/// Type-2 tag encapsulation: TLV blocks (0x03 = NDEF message, 0xFE terminator).
pub fn t2_tlv_wrap(message: &[u8]) -> Vec<u8> {
    let mut out = vec![0x03];
    if message.len() < 0xFF {
        out.push(message.len() as u8);
    } else {
        out.push(0xFF);
        out.extend_from_slice(&(message.len() as u16).to_be_bytes());
    }
    out.extend_from_slice(message);
    out.push(0xFE);
    out
}

/// Inverse of [`t2_tlv_wrap`] (skips unrelated TLVs, stops at terminator).
pub fn t2_tlv_unwrap(data: &[u8]) -> Result<Vec<u8>, String> {
    let mut i = 0;
    while i < data.len() {
        let t = *data.get(i).ok_or("truncated tlv")?;
        if t == 0xFE {
            return Ok(Vec::new());
        }
        i += 1;
        let len = match *data.get(i).ok_or("truncated tlv length")? {
            0xFF => {
                let hi = *data.get(i + 1).ok_or("truncated long length")? as usize;
                let lo = *data.get(i + 2).ok_or("truncated long length")? as usize;
                i += 3;
                (hi << 8) | lo
            }
            l => {
                i += 1;
                l as usize
            }
        };
        let v = data.get(i..i + len).ok_or("tlv value overrun")?;
        if t == 0x03 {
            return Ok(v.to_vec());
        }
        i += len;
    }
    Err("no NDEF TLV found".into())
}

// --- Ox payment-request handoff -------------------------------------------
//
// Tap-to-initiate: a peer (merchant display, kiosk, another Ox device)
// exposes an NDEF Type-2 tag whose message carries a URI record with the
// custom `oxpay://` scheme; the tapping device reads the tag and turns it
// into a validated [`PaymentRequest`] that feeds the authorize path. This
// is the pre-standardization custom-scheme approach real wallet apps use;
// a standards-track handover record can replace it without changing the
// request struct.

/// A payment request carried by a handoff tag.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PaymentRequest {
    /// Amount in minor units (cents), > 0.
    pub amount_minor: u64,
    /// Merchant identifier: `[A-Za-z0-9._-]`, 1..=64 chars.
    pub merchant: String,
    /// Optional transaction reference, same charset as `merchant`.
    pub reference: Option<String>,
}

const OXPAY_SCHEME: &str = "oxpay://req?";

fn valid_field(s: &str, max: usize) -> bool {
    !s.is_empty()
        && s.len() <= max
        && s.bytes().all(|b| {
            b.is_ascii_alphanumeric() || b == b'.' || b == b'_' || b == b'-'
        })
}

/// Encode a request as an `oxpay://req?` URI. Fields are restricted to a
/// strict charset (no percent-encoding surface) — building fails loudly on
/// anything outside it.
pub fn payment_request_uri(r: &PaymentRequest) -> Result<String, String> {
    if r.amount_minor == 0 {
        return Err("amount_minor must be > 0".into());
    }
    if !valid_field(&r.merchant, 64) {
        return Err("invalid merchant field".into());
    }
    let mut uri = format!(
        "{}a={}&m={}",
        OXPAY_SCHEME, r.amount_minor, r.merchant
    );
    if let Some(t) = &r.reference {
        if !valid_field(t, 64) {
            return Err("invalid reference field".into());
        }
        uri.push_str(&format!("&t={t}"));
    }
    Ok(uri)
}

/// Parse an `oxpay://req?` URI into a validated request. Unknown query
/// parameters are rejected (no silent extension surface).
pub fn parse_payment_uri(uri: &str) -> Result<PaymentRequest, String> {
    let rest = uri
        .strip_prefix(OXPAY_SCHEME)
        .ok_or("not an oxfay handoff URI")?;
    let mut amount = None;
    let mut merchant = None;
    let mut reference = None;
    for kv in rest.split('&') {
        let (k, v) = kv.split_once('=').ok_or("malformed query pair")?;
        match k {
            "a" => {
                amount = Some(
                    v.parse::<u64>().map_err(|_| "bad amount")?,
                )
            }
            "m" => merchant = Some(v.to_string()),
            "t" => reference = Some(v.to_string()),
            _ => return Err(format!("unknown query key: {k}")),
        }
    }
    let amount_minor = amount.ok_or("missing amount")?;
    if amount_minor == 0 {
        return Err("amount must be > 0".into());
    }
    let merchant = merchant.ok_or("missing merchant")?;
    if !valid_field(&merchant, 64) {
        return Err("invalid merchant field".into());
    }
    if let Some(t) = &reference {
        if !valid_field(t, 64) {
            return Err("invalid reference field".into());
        }
    }
    Ok(PaymentRequest { amount_minor, merchant, reference })
}

/// Build the full Type-2 tag image for a request: an NDEF message with a
/// human-readable Text record + the `oxpay://` URI record, TLV-wrapped.
pub fn build_handoff_tag(r: &PaymentRequest) -> Result<Vec<u8>, String> {
    let uri = payment_request_uri(r)?;
    let label = format!("Ox payment request: {} ({} minor units)", r.merchant, r.amount_minor);
    let msg = build_message(&[text_record(&label, "en"), uri_record(&uri)])?;
    Ok(t2_tlv_wrap(&msg))
}

/// Read a Type-2 tag image into a request: unwrap TLV, parse the NDEF
/// message, find the first URI record with the `oxpay://` scheme.
pub fn read_handoff_tag(tag: &[u8]) -> Result<PaymentRequest, String> {
    let msg = t2_tlv_unwrap(tag)?;
    for rec in parse_message(&msg)? {
        if rec.tnf == TNF_WELL_KNOWN && rec.r#type == b"U" {
            // URI record payload: 1 prefix byte + rest; prefix 0 = none.
            let prefix = *rec.payload.first().ok_or("empty URI payload")? as usize;
            const PREFIXES: [&str; 4] =
                ["", "https://www.", "http://www.", "https://"];
            let rest = std::str::from_utf8(&rec.payload[1..])
                .map_err(|_| "URI payload not UTF-8")?;
            let prefix = PREFIXES.get(prefix).ok_or("unknown URI prefix")?;
            return parse_payment_uri(&format!("{prefix}{rest}"));
        }
    }
    Err("no URI record in handoff message".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_record_roundtrip() {
        let msg = build_message(&[text_record("Ox OS", "en")]).unwrap();
        let parsed = parse_message(&msg).unwrap();
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].r#type, b"T");
        assert_eq!(parsed[0].payload[0], 2); // lang len
        assert_eq!(&parsed[0].payload[3..], &b"Ox OS"[..]);
    }

    #[test]
    fn uri_prefix_compression() {
        let r = uri_record("https://ox.example.dev/pay");
        assert_eq!(r.payload[0], 3); // "https://" prefix code
        assert_eq!(&r.payload[1..], &b"ox.example.dev/pay"[..]);
        let msg = build_message(&[r]).unwrap();
        let parsed = parse_message(&msg).unwrap();
        assert_eq!(parsed[0].payload[0], 3);
    }

    #[test]
    fn multi_record_mb_me_flags() {
        let msg = build_message(&[text_record("a", "en"), uri_record("https://x.io")]).unwrap();
        let parsed = parse_message(&msg).unwrap();
        assert_eq!(parsed.len(), 2);
        assert_eq!(&parsed[0].payload[3..], &b"a"[..]);
    }

    #[test]
    fn t2_tlv_roundtrip() {
        let msg = build_message(&[text_record("hello", "en")]).unwrap();
        let wrapped = t2_tlv_wrap(&msg);
        assert_eq!(wrapped[0], 0x03);
        assert_eq!(*wrapped.last().unwrap(), 0xFE);
        assert_eq!(t2_tlv_unwrap(&wrapped).unwrap(), msg);
    }

    #[test]
    fn malformed_rejected() {
        assert!(build_message(&[]).is_err());
        assert!(parse_message(&[0xD1]).is_err()); // truncated
    }

    fn req() -> PaymentRequest {
        PaymentRequest {
            amount_minor: 1250,
            merchant: "cafe.example".into(),
            reference: Some("order-9".into()),
        }
    }

    #[test]
    fn handoff_uri_roundtrip() {
        let uri = payment_request_uri(&req()).unwrap();
        assert_eq!(uri, "oxpay://req?a=1250&m=cafe.example&t=order-9");
        assert_eq!(parse_payment_uri(&uri).unwrap(), req());
    }

    #[test]
    fn handoff_uri_reference_optional() {
        let r = PaymentRequest { reference: None, ..req() };
        let uri = payment_request_uri(&r).unwrap();
        assert_eq!(parse_payment_uri(&uri).unwrap(), r);
    }

    #[test]
    fn handoff_uri_rejects_bad_input() {
        assert!(payment_request_uri(&PaymentRequest {
            amount_minor: 0,
            ..req()
        })
        .is_err());
        assert!(payment_request_uri(&PaymentRequest {
            merchant: "bad space".into(),
            ..req()
        })
        .is_err());
        assert!(parse_payment_uri("https://ox.io/pay?a=1").is_err());
        assert!(parse_payment_uri("oxpay://req?a=1250").is_err()); // no merchant
        assert!(parse_payment_uri("oxpay://req?a=0&m=x").is_err());
        assert!(parse_payment_uri("oxpay://req?a=1250&m=x&z=1").is_err()); // unknown key
    }

    #[test]
    fn handoff_tag_roundtrip() {
        let tag = build_handoff_tag(&req()).unwrap();
        assert_eq!(tag[0], 0x03);
        assert_eq!(*tag.last().unwrap(), 0xFE);
        assert_eq!(read_handoff_tag(&tag).unwrap(), req());
    }

    #[test]
    fn handoff_tag_rejects_garbage() {
        assert!(read_handoff_tag(&[0x01, 0x02]).is_err()); // no NDEF TLV
        assert!(read_handoff_tag(&[]).is_err());
        // TLV present but message has no URI record
        let msg = build_message(&[text_record("no uri", "en")]).unwrap();
        assert!(read_handoff_tag(&t2_tlv_wrap(&msg)).is_err());
    }
}
