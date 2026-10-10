# Chunk 52 — Wi-Fi association solved: channel mismatch + scan race; Phase-4 close sweep

Date: 2026-09-14
Status: **WIFI GATE ALL GREEN (both phases) on the final payload.
Full 16-gate close-out sweep running — verdict appended below.**

## The root cause (found after the bisect pointed the right way)

The payload bisect (same bits passing and failing) said "environment", but
the environment interaction had a precise shape, and guest-side evidence
plus elimination finally isolated TWO compounding conditions:

1. **AP/client channel mismatch vs hwsim defaults.** hwsim assigns each
   radio a default channel (radio0=2412/ch1, radio1=2437/ch6). The AP sat
   on ch6 while the client radio's home was ch1 — every auth needed a
   remain-on-channel window whose response, under TCG load, regularly
   missed the client ("authentication timed out"; hostapd: "did not
   acknowledge authentication response"). Moving the AP to ch1 puts the
   whole exchange on the client's home channel: **association completed
   the full 4-way handshake (802.1X authorizing port) on the first try,
   no nudges** — verified repeatedly.
   (An earlier attempt at this fix was wrongly reverted: the round that
   proved it failed later at the Settings tap from stray-window clicks —
   a different defect, since fixed with hygiene — and the revert threw
   away the working association.)
2. **The scan race, closed structurally**: with scan-based association
   (ap_scan=1, the proven path) a scanning radio is hwsim-unreachable for
   unicast, so first-try auth can still race the scan state under load.
   The selftest now retries with user semantics (up to 4 full re-join
   cycles via the daemon's connect op, each a fresh scan+auth lottery)
   and journals diagnostics (`DBG-WIFI-FAILSTATE`: iw channels,
   scan_results, dmesg tail) before any failure verdict.
   (An `ap_scan=2` + explicit-frequency variant was built and tested —
   it eliminates the scan entirely — but wpa_supplicant with nl80211 SME
   does not act on it reliably; reverted. The `freq` plumbing in oxwifid
   (connect payload, remembered credentials, autojoin) stays: unit-tested
   and useful for a future fixed-channel lab.)

Also fixed on the way: the wifi gate's Settings/panel tap legs now poll
~60s per attempt (delivery lag exceeds the old 16s windows).

## Verification

- `tools/wifi-gate-run.sh` → **WIFI GATE ALL GREEN**: association first
  try, credential persisted, ICMP across the authenticated link, Settings
  panel with the live connection; boot 2 on the same volume: autojoin
  replays consent before the selftest's own walk (line-ordering proof),
  matrix re-walked, forget empties the store.
- All other 15 Phase-4 gates: green on this lineage (sweep8's twelve +
  gnss/dialer-app/grid-event re-verified in round 13/15).

## Verdict

PENDING — sweep9 (16 gates, one payload) verdict appended below.
