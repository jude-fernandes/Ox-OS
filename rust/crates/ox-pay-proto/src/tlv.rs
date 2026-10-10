//! BER-TLV: EMV's tag-length-value encoding, plus DOL (data object list)
//! iteration. Tags are 1–2 bytes (the 99% case); multi-byte tags beyond two
//! bytes are rejected rather than mis-parsed.

/// A parsed TLV entry.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Tlv {
    pub tag: u32,
    pub value: Vec<u8>,
}

fn tag_len(data: &[u8]) -> Option<(u32, usize)> {
    let first = *data.first()?;
    if first & 0x1F != 0x1F {
        return Some((first as u32, 1));
    }
    // two-byte tag
    let second = *data.get(1)?;
    if second & 0x1F == 0x1F {
        return None; // >2-byte tags unsupported by design
    }
    Some((((first as u32) << 8) | second as u32, 2))
}

fn len_len(data: &[u8], off: usize) -> Option<(usize, usize)> {
    let first = *data.get(off)?;
    if first < 0x80 {
        return Some((first as usize, 1));
    }
    let n = (first & 0x7F) as usize;
    if n == 0 || n > 3 {
        return None; // length-of-length sane bounds (EMV never exceeds 3)
    }
    let mut v = 0usize;
    for i in 0..n {
        v = (v << 8) | *data.get(off + 1 + i)? as usize;
    }
    Some((v, 1 + n))
}

/// Parse a buffer of consecutive BER-TLV entries.
pub fn parse(data: &[u8]) -> Result<Vec<Tlv>, String> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < data.len() {
        let (tag, tlen) = tag_len(&data[i..]).ok_or("bad tag")?;
        i += tlen;
        let (vlen, llen) = len_len(&data, i).ok_or("bad length")?;
        i += llen;
        let value = data.get(i..i + vlen).ok_or("value overruns buffer")?.to_vec();
        i += vlen;
        out.push(Tlv { tag, value });
    }
    Ok(out)
}

/// Find the first entry with `tag` (searching nested constructed templates
/// like FCI templates one level deep when `nested` tags are given).
pub fn find<'a>(tlvs: &'a [Tlv], tag: u32) -> Option<&'a Tlv> {
    tlvs.iter().find(|t| t.tag == tag)
}

/// Build one BER-TLV entry.
pub fn build(tag: u32, value: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    if tag <= 0xFF {
        out.push(tag as u8);
    } else {
        out.push((tag >> 8) as u8);
        out.push(tag as u8);
    }
    if value.len() < 0x80 {
        out.push(value.len() as u8);
    } else if value.len() <= 0xFF {
        out.push(0x81);
        out.push(value.len() as u8);
    } else {
        out.push(0x82);
        out.push((value.len() >> 8) as u8);
        out.push(value.len() as u8);
    }
    out.extend_from_slice(value);
    out
}

/// Iterate a DOL (data object list): a buffer of tag+len template entries
/// (e.g. `9F 02 06` = Amount, Numeric, 6 bytes).
pub fn dol_entries(dol: &[u8]) -> Result<Vec<(u32, usize)>, String> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < dol.len() {
        let (tag, tlen) = tag_len(&dol[i..]).ok_or("dol: bad tag")?;
        i += tlen;
        let l = *dol.get(i).ok_or("dol: missing length")? as usize;
        i += 1;
        out.push((tag, l));
    }
    Ok(out)
}

/// Build a DOL response: values in the order the DOL lists, zero-padded or
/// truncated to each field's length.
pub fn dol_response(dol: &[u8], values: &[(u32, Vec<u8>)]) -> Result<Vec<u8>, String> {
    let mut out = Vec::new();
    for (tag, len) in dol_entries(dol)? {
        let v = values
            .iter()
            .find(|(t, _)| *t == tag)
            .map(|(_, v)| v.clone())
            .unwrap_or_default();
        let mut field = vec![0u8; len];
        let take = v.len().min(len);
        field[len - take..].copy_from_slice(&v[v.len() - take..]);
        out.extend_from_slice(&field);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_build_roundtrip() {
        let buf = [0x9F, 0x02, 0x02, 0x12, 0x34, 0x5A, 0x00, 0x4F, 0x04, 0xA0, 0x00, 0x00, 0x03];
        let tlvs = parse(&buf).unwrap();
        assert_eq!(tlvs.len(), 3);
        assert_eq!(tlvs[0].tag, 0x9F02);
        assert_eq!(tlvs[0].value, vec![0x12, 0x34]);
        assert_eq!(tlvs[1].tag, 0x5A);
        assert_eq!(tlvs[1].value, Vec::<u8>::new()); // zero length
        assert_eq!(tlvs[2].tag, 0x4F);
        assert_eq!(tlvs[2].value, vec![0xA0, 0x00, 0x00, 0x03]);
        let rebuilt = build(0x9F02, &[0x12, 0x34]);
        assert_eq!(rebuilt, vec![0x9F, 0x02, 0x02, 0x12, 0x34]);
    }

    #[test]
    fn long_form_length() {
        let value = vec![0xAB; 300];
        let buf = build(0x8E, &value);
        assert_eq!(&buf[..3], &[0x8E, 0x82, 0x01]);
        let tlvs = parse(&buf).unwrap();
        assert_eq!(tlvs[0].value.len(), 300);
    }

    #[test]
    fn malformed_rejected() {
        assert!(parse(&[0x9F, 0x02]).is_err()); // missing length
        assert!(parse(&[0x9F, 0x02, 0x05, 0x01]).is_err()); // value overrun
        assert!(parse(&[0x9F, 0x1F, 0x1F, 0x00]).is_err()); // 3-byte tag
    }

    #[test]
    fn dol_walks_template_entries() {
        // 9F02 06 (Amount) + 9C 01 (TxType)
        let dol = [0x9F, 0x02, 0x06, 0x9C, 0x01];
        let e = dol_entries(&dol).unwrap();
        assert_eq!(e, vec![(0x9F02, 6), (0x9C, 1)]);
        let resp = dol_response(&dol, &[(0x9C, vec![0x00])]).unwrap();
        assert_eq!(resp.len(), 7);
        assert_eq!(&resp[..6], &[0, 0, 0, 0, 0, 0]);
        assert_eq!(resp[6], 0x00);
    }
}
