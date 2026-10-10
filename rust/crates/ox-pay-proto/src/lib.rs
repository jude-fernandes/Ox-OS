//! Ox OS payment protocol layer — everything above the NFC hardware seam.
//!
//! * [`sha256`] / [`hmac`]: the only crypto in the crate (real primitives,
//!   known-vector tested). EMV cryptograms here are explicitly *simulated*
//!   until Phase 6 wires the eSE — see `emv::SIMULATED_CRYPTOGRAPHY`.
//! * [`tlv`]: BER-TLV (EMV's encoding) parse/build/DOL.
//! * [`apdu`]: ISO 7816-4 command/response units and status words.
//! * [`ndef`]: NDEF records + Type-2 tag TLV (reader mode / handoff).
//! * [`emv`]: HCE mini-kernel — PPSE/AID selection and an Ox payment flow
//!   over the `PaymentTerminal` trait (hardware backends plug in later).

pub mod apdu;
pub mod emv;
pub mod hmac;
pub mod ndef;
pub mod sha256;
pub mod tlv;
