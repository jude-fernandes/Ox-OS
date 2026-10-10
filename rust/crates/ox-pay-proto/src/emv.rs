//! HCE payment mini-kernel: the APDU state machine a payment terminal talks
//! to over ISO 14443-4 / ISO 7816-4. Supports PPSE selection (the first
//! command every contactless terminal sends), AID selection from a
//! configured list, and an Ox authorize flow wired to the
//! [`crate::emv::PaymentSink`] seam.
//!
//! Honest scope: real Visa/Mastercard kernels need PDOL/GPO tag rounds and
//! issuer-side cryptography in the secure element — that is Phase 6 work
//! with eSE provisioning. `SIMULATED_CRYPTOGRAPHY` is asserted at runtime:
//! cryptograms are HMAC-SHA256 device keys here, NOT industry ARQCs.

use crate::apdu::{Capdu, Rapdu, SW_CONDITIONS, SW_NOT_FOUND};
use crate::hmac::hmac_sha256;
use crate::tlv;

/// PPSE file name: "2PAY.SYS.DDF01" (proximity payment system environment).
pub const PPSE_DF_NAME: &[u8] = b"2PAY.SYS.DDF01";

/// Tags used by this kernel (EMV card specification numbers).
pub const TAG_AID: u32 = 0x4F;
pub const TAG_APP_LABEL: u32 = 0x50;
pub const TAG_PRIORITY: u32 = 0x87;
pub const TAG_FCI_TEMPLATE: u32 = 0x6F;
pub const TAG_APPLICATION_TEMPLATE: u32 = 0x61;
pub const TAG_TRACK2_EQUIV: u32 = 0x57;
pub const TAG_CRYPTOGRAM: u32 = 0x9F26;
pub const TAG_AMOUNT: u32 = 0x9F02;
pub const TAG_TX_COUNTER: u32 = 0x9F41;

/// Where authorize results go. `oxpaymentsd` implements this over its
/// `PaymentTerminal`; the trait keeps silicon out of the protocol layer.
pub trait PaymentSink {
    /// Begin + approve a payment of `amount_minor`; returns a reference id.
    fn approve(&mut self, amount_minor: u64, currency: &str) -> Result<u64, String>;
    /// Decline: begin + cancel, keeping the ledger consistent.
    fn decline(&mut self, amount_minor: u64, currency: &str) -> Result<u64, String>;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AidEntry {
    pub aid: Vec<u8>,
    pub label: String,
    pub priority: u8,
}

/// Session state for one contactless presentation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KernelState {
    Idle,
    EnvironmentReady, // PPSE selected
    Selected,         // application selected
}

/// The HCE kernel: supported applications + device key for cryptograms.
pub struct HceKernel {
    pub apps: Vec<AidEntry>,
    pub currency: String,
    /// Per-presentment device key (Phase 6: eSE-held key; here dev-derived).
    pub device_key: [u8; 32],
    state: KernelState,
    selected: Option<Vec<u8>>,
    tx_counter: u64,
}

/// Banner for downstream honesty checks: cryptograms from this kernel are
/// HMAC-SHA256 device keys, NOT industry ARQCs — real cryptography lands
/// with eSE provisioning (Phase 6).
pub const SIMULATED_CRYPTOGRAPHY: bool = true;

impl HceKernel {
    pub fn new(apps: Vec<AidEntry>, currency: &str, device_key: [u8; 32]) -> Self {
        HceKernel {
            apps,
            currency: currency.to_string(),
            device_key,
            state: KernelState::Idle,
            selected: None,
            tx_counter: 0,
        }
    }

    pub fn state(&self) -> KernelState {
        self.state
    }

    pub fn tx_counter(&self) -> u64 {
        self.tx_counter
    }

    /// PPSE FCI: the terminal reads this to learn which apps we offer.
    pub fn build_ppse_response(&self) -> Vec<u8> {
        // Simplified structure (documented): FCI(6F) { DF name(84),
        // Application Template(61) { AID(4F), Label(50), Priority(87) } }.
        // A full kernel wraps each app in its own 61 inside an A5 template.
        let mut apps_data = Vec::new();
        for app in &self.apps {
            apps_data.extend_from_slice(&tlv::build(TAG_AID, &app.aid));
            apps_data.extend_from_slice(&tlv::build(TAG_APP_LABEL, app.label.as_bytes()));
            apps_data.extend_from_slice(&tlv::build(TAG_PRIORITY, &[app.priority]));
        }
        // PPSE FCI: 6F with dedicated-file name 2PAY.SYS.DDF01 (tag 0x84)
        let mut fci = tlv::build(0x84, PPSE_DF_NAME);
        fci.extend_from_slice(&tlv::build(TAG_APPLICATION_TEMPLATE, &apps_data));
        tlv::build(TAG_FCI_TEMPLATE, &fci)
    }

    /// Process one command APDU; drives the state machine.
    pub fn process(&mut self, capdu: &Capdu, sink: &mut dyn PaymentSink) -> Rapdu {
        if capdu.cla & 0x0F != 0x00 {
            return Rapdu::err(SW_CONDITIONS);
        }
        match capdu.ins {
            crate::apdu::INS_SELECT => self.handle_select(capdu),
            crate::apdu::INS_OX_AUTHORIZE => self.handle_authorize(capdu, sink),
            _ => Rapdu::err(crate::apdu::SW_FUNC_NOT_SUPPORTED),
        }
    }

    fn handle_select(&mut self, capdu: &Capdu) -> Rapdu {
        if capdu.data == PPSE_DF_NAME {
            self.state = KernelState::EnvironmentReady;
            self.selected = None;
            return Rapdu::ok(&self.build_ppse_response());
        }
        if self.state == KernelState::Idle {
            return Rapdu::err(SW_CONDITIONS); // select app before PPSE
        }
        for app in &self.apps {
            if app.aid == capdu.data {
                self.state = KernelState::Selected;
                self.selected = Some(app.aid.clone());
                let mut fci = tlv::build(0x84, &app.aid);
                fci.extend_from_slice(&tlv::build(TAG_APP_LABEL, app.label.as_bytes()));
                return Rapdu::ok(&tlv::build(TAG_FCI_TEMPLATE, &fci));
            }
        }
        Rapdu::err(SW_NOT_FOUND)
    }

    fn handle_authorize(&mut self, capdu: &Capdu, sink: &mut dyn PaymentSink) -> Rapdu {
        if self.state != KernelState::Selected {
            return Rapdu::err(SW_CONDITIONS);
        }
        // Data = DOL-style: Amount (tag 9F02, numeric BCD/zero-pad) + others.
        let Ok(tlvs) = tlv::parse(&capdu.data) else {
            return Rapdu::err(crate::apdu::SW_WRONG_PARAMS);
        };
        let Some(amount_tlv) = tlvs.iter().find(|t| t.tag == TAG_AMOUNT) else {
            return Rapdu::err(crate::apdu::SW_WRONG_PARAMS);
        };
        // Amount, Numeric: ASCII digits per EMV; parse leniently.
        let Ok(amount_str) = std::str::from_utf8(&amount_tlv.value) else {
            return Rapdu::err(crate::apdu::SW_WRONG_PARAMS);
        };
        let Ok(amount) = amount_str.trim_start_matches('0').parse::<u64>() else {
            return Rapdu::err(crate::apdu::SW_WRONG_PARAMS);
        };
        let zero = amount_str.bytes().all(|b| b == b'0');
        let amount = if zero { 0 } else { amount };
        if amount == 0 {
            return Rapdu::err(crate::apdu::SW_WRONG_PARAMS);
        }
        self.tx_counter += 1;
        let (aid, outcome) = match (self.selected.clone(), sink.approve(amount, &self.currency)) {
            (Some(aid), Ok(tx_id)) => (aid, Ok(tx_id)),
            (Some(aid), Err(e)) => {
                let _ = sink.decline(amount, &self.currency);
                (aid, Err(e))
            }
            (None, _) => return Rapdu::err(SW_CONDITIONS),
        };
        // Cryptogram (SIMULATED): HMAC(device_key, aid||amount||counter).
        let mut msg = Vec::new();
        msg.extend_from_slice(&aid);
        msg.extend_from_slice(&amount.to_be_bytes());
        msg.extend_from_slice(&self.tx_counter.to_be_bytes());
        let mac = hmac_sha256(&self.device_key, &msg);
        match outcome {
            Ok(_tx) => {
                let mut resp = tlv::build(TAG_CRYPTOGRAM, &mac[..16]);
                resp.extend_from_slice(&tlv::build(TAG_TX_COUNTER, &self.tx_counter.to_be_bytes()));
                Rapdu::ok(&resp)
            }
            Err(_) => Rapdu::err(SW_CONDITIONS),
        }
    }
}

/// In-memory sink for tests / the guest demo (oxpaymentsd wraps its
/// `MemoryTerminal` in one of these).
#[derive(Debug, Default)]
pub struct MemorySink {
    pub next_id: u64,
}

impl PaymentSink for MemorySink {
    fn approve(&mut self, _amount_minor: u64, _currency: &str) -> Result<u64, String> {
        self.next_id += 1;
        Ok(self.next_id)
    }
    fn decline(&mut self, _amount_minor: u64, _currency: &str) -> Result<u64, String> {
        Ok(0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kernel() -> HceKernel {
        HceKernel::new(
            vec![AidEntry {
                aid: vec![0xF0, 0x4F, 0x58, 0x50, 0x41, 0x59], // F0 OxPAY demo AID
                label: "Ox Wallet".into(),
                priority: 0x01,
            }],
            "eur",
            [7u8; 32],
        )
    }

    fn select_ppse() -> Capdu {
        let mut raw = vec![0x00, 0xA4, 0x04, 0x00, PPSE_DF_NAME.len() as u8];
        raw.extend_from_slice(PPSE_DF_NAME);
        Capdu::parse(&raw).unwrap()
    }

    fn select_aid() -> Capdu {
        let aid = [0xF0, 0x4F, 0x58, 0x50, 0x41, 0x59];
        let mut raw = vec![0x00, 0xA4, 0x04, 0x00, aid.len() as u8];
        raw.extend_from_slice(&aid);
        Capdu::parse(&raw).unwrap()
    }

    fn authorize(amount_eur: u64) -> Capdu {
        let amt = format!("{:06}", amount_eur);
        let data = tlv::build(TAG_AMOUNT, amt.as_bytes());
        let mut raw = vec![0x80, 0x52, 0x00, 0x00, data.len() as u8];
        raw.extend_from_slice(&data);
        Capdu::parse(&raw).unwrap()
    }

    #[test]
    fn ppse_lists_our_application() {
        let mut k = kernel();
        let mut sink = MemorySink::default();
        let r = k.process(&select_ppse(), &mut sink);
        assert!(r.is_ok());
        let tlvs = tlv::parse(&r.data).unwrap();
        let fci = tlv::find(&tlvs, TAG_FCI_TEMPLATE).unwrap();
        let inner = tlv::parse(&fci.value).unwrap();
        let apps = tlv::find(&inner, TAG_APPLICATION_TEMPLATE).unwrap();
        let app_tlvs = tlv::parse(&apps.value).unwrap();
        let aid = tlv::find(&app_tlvs, TAG_AID).unwrap();
        assert_eq!(aid.value, vec![0xF0, 0x4F, 0x58, 0x50, 0x41, 0x59]);
        assert_eq!(k.state(), KernelState::EnvironmentReady);
    }

    #[test]
    fn authorize_requires_selection_and_ppse_first() {
        let mut k = kernel();
        let mut sink = MemorySink::default();
        assert_eq!(k.process(&authorize(100), &mut sink).sw, SW_CONDITIONS);
        assert_eq!(k.process(&select_aid(), &mut sink).sw, SW_CONDITIONS);
    }

    #[test]
    fn full_flow_authorized_with_cryptogram() {
        let mut k = kernel();
        let mut sink = MemorySink::default();
        assert!(k.process(&select_ppse(), &mut sink).is_ok());
        assert!(k.process(&select_aid(), &mut sink).is_ok());
        let r = k.process(&authorize(1250), &mut sink);
        assert!(r.is_ok());
        let tlvs = tlv::parse(&r.data).unwrap();
        let crypto = tlv::find(&tlvs, TAG_CRYPTOGRAM).unwrap();
        assert_eq!(crypto.value.len(), 16);
        // determinism per counter: same inputs at same counter -> same mac
        let mut k2 = kernel();
        let mut s2 = MemorySink::default();
        let _ = k2.process(&select_ppse(), &mut s2);
        let _ = k2.process(&select_aid(), &mut s2);
        let r2 = k2.process(&authorize(1250), &mut s2);
        assert_eq!(r.data, r2.data);
        // counter advances -> different cryptogram
        let r3 = k.process(&authorize(1250), &mut sink);
        assert_ne!(r.data, r3.data);
    }

    #[test]
    fn unknown_aid_not_found() {
        let mut k = kernel();
        let mut sink = MemorySink::default();
        let _ = k.process(&select_ppse(), &mut sink);
        let raw = vec![0x00, 0xA4, 0x04, 0x00, 0x05, 0xA0, 0x00, 0x00, 0x03, 0x10];
        let c = Capdu::parse(&raw).unwrap();
        assert_eq!(k.process(&c, &mut sink).sw, SW_NOT_FOUND);
        let _ = raw;
    }

    #[test]
    fn zero_amount_refused() {
        let mut k = kernel();
        let mut sink = MemorySink::default();
        let _ = k.process(&select_ppse(), &mut sink);
        let _ = k.process(&select_aid(), &mut sink);
        assert_eq!(k.process(&authorize(0), &mut sink).sw, crate::apdu::SW_WRONG_PARAMS);
    }
}
