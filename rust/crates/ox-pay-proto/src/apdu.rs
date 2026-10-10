//! ISO 7816-4 command/response APDUs (short/Lc form) and status words.

/// A parsed command APDU (case 1–4 short form).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Capdu {
    pub cla: u8,
    pub ins: u8,
    pub p1: u8,
    pub p2: u8,
    pub data: Vec<u8>,
    pub le: Option<u8>,
}

impl Capdu {
    /// Parse short-form APDUs: 4-byte header, optional Lc+data, optional Le.
    /// (Extended APDUs are not needed on the HCE side — readers send short.)
    pub fn parse(raw: &[u8]) -> Result<Capdu, String> {
        if raw.len() < 4 {
            return Err("apdu too short".into());
        }
        let (cla, ins, p1, p2) = (raw[0], raw[1], raw[2], raw[3]);
        let mut data = Vec::new();
        let mut le = None;
        let mut i = 4;
        let rest = raw.len() - i;
        if rest == 1 {
            le = Some(raw[4]);
        } else if rest >= 2 {
            let lc = raw[4] as usize;
            data = raw.get(5..5 + lc).ok_or("Lc overruns buffer")?.to_vec();
            i = 5 + lc;
            if raw.len() > i {
                le = Some(raw[i]);
            }
        }
        Ok(Capdu { cla, ins, p1, p2, data, le })
    }

    pub fn build(cla: u8, ins: u8, p1: u8, p2: u8, data: &[u8], le: Option<u8>) -> Vec<u8> {
        let mut out = vec![cla, ins, p1, p2];
        if !data.is_empty() || le.is_some() && !data.is_empty() {
            out.push(data.len() as u8);
            out.extend_from_slice(data);
        }
        if let Some(le) = le {
            if le != 0 || !data.is_empty() {
                out.push(le);
            }
        }
        out
    }
}

/// Response APDU = data + 2-byte status word.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rapdu {
    pub data: Vec<u8>,
    pub sw: u16,
}

impl Rapdu {
    pub fn ok(data: &[u8]) -> Rapdu {
        Rapdu { data: data.to_vec(), sw: SW_OK }
    }
    pub fn err(sw: u16) -> Rapdu {
        Rapdu { data: Vec::new(), sw }
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut out = self.data.clone();
        out.extend_from_slice(&self.sw.to_be_bytes());
        out
    }

    pub fn is_ok(&self) -> bool {
        self.sw == SW_OK
    }
}

pub const SW_OK: u16 = 0x9000;
/// Command not allowed / conditions not satisfied.
pub const SW_CONDITIONS: u16 = 0x6985;
/// File or AID not found.
pub const SW_NOT_FOUND: u16 = 0x6A82;
/// Wrong parameters (P1/P2).
pub const SW_WRONG_PARAMS: u16 = 0x6A86;
/// Function not supported.
pub const SW_FUNC_NOT_SUPPORTED: u16 = 0x6A81;
/// Memory failure.
pub const SW_MEMORY_FAILURE: u16 = 0x6581;

pub const INS_SELECT: u8 = 0xA4;
/// Our Ox kernel extension: authorize a payment (not ISO-standardized).
pub const INS_OX_AUTHORIZE: u8 = 0x52;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_all_four_cases() {
        // case 1/2: header only (Le implied by reader)
        let c = Capdu::parse(&[0x00, 0xA4, 0x04, 0x00]).unwrap();
        assert!(c.data.is_empty() && c.le.is_none());
        // case 2: header + Le
        let c = Capdu::parse(&[0x00, 0xA4, 0x04, 0x00, 0x00]).unwrap();
        assert!(c.data.is_empty() && c.le == Some(0));
        // case 3: SELECT with data (AID), no Le
        let c = Capdu::parse(&[0x00, 0xA4, 0x04, 0x00, 0x07, 1, 2, 3, 4, 5, 6, 7]).unwrap();
        assert_eq!(c.data.len(), 7);
        assert_eq!(c.le, None);
        // case 4: data + Le
        let c = Capdu::parse(&[0x80, 0x52, 0x00, 0x00, 0x06, 1, 2, 3, 4, 5, 6, 0x10]).unwrap();
        assert_eq!(c.data.len(), 6);
        assert_eq!(c.le, Some(0x10));
    }

    #[test]
    fn build_encode_roundtrip() {
        let r = Rapdu::ok(&[0xAA, 0xBB]);
        assert_eq!(r.encode(), vec![0xAA, 0xBB, 0x90, 0x00]);
        assert!(r.is_ok());
        assert_eq!(Rapdu::err(SW_NOT_FOUND).encode(), vec![0x6A, 0x82]);
    }

    #[test]
    fn malformed_rejected() {
        assert!(Capdu::parse(&[0x00, 0xA4]).is_err());
        assert!(Capdu::parse(&[0x00, 0xA4, 0x04, 0x00, 0x07, 0x01]).is_err());
    }

}
