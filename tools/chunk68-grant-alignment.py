#!/usr/bin/env python3
"""Chunk 68: align every grant seed with the kernel-verified caller.

Post-chunk-68 the consult identity is the peer's /proc comm, so a grant
only works when it names the CALLER's comm:
  - selftests drive daemons through oxctl        -> grant `oxctl`
  - the Messaging/Dialer/Camera apps consult through their own process
    (ox-sms / ox-dialer / ox-camera — the manifest `bin` names)
  - the Settings wifi panel consults as ox-settings
  - gnssd consults locationd on every fix                       -> `gnssd`
Idempotent: exact-string replacements; misses are reported loudly."""
import sys
from pathlib import Path

SRC = Path("/root/oxbuild/system/s6-rc-source")

# (file, old fragment, new fragment) — ALL occurrences rename: the
# labels are the selftest's grant identity in seeds AND in the journal
# assertions that must keep matching post-68 (journals now say oxctl).
EDITS = [
    ("contacts-selftest/run", '"app":"contacts.test"', '"app":"oxctl"'),
    ("fake-providers-selftest/run", '"app":"location.test"', '"app":"oxctl"'),
    ("fake-providers-selftest/run", '"app":"messages.test"', '"app":"oxctl"'),
    ("gnss-selftest/run", '"app":"gnss.test"', '"app":"gnssd"'),
    ("messages-store-selftest/run", '"app":"messages.store"', '"app":"oxctl"'),
    ("nfc-selftest/run", '"app":"nfc.test"', '"app":"oxctl"'),
    ("usb-selftest/run", '"app":"usb.test"', '"app":"oxctl"'),
    ("notifd-selftest/run", '"app":"test.app","permission":"post-notification"', '"app":"oxctl","permission":"post-notification"'),
    ("alerts-selftest/run", '"app":"alerts.test"', '"app":"oxctl"'),
    ("camera-selftest/run", '"app":"camera.test"', '"app":"oxctl"'),
    ("sms-app-selftest/run", '"app":"Messaging"', '"app":"ox-sms"'),
    ("telephony-app-selftest/run", '"app":"Dialer"', '"app":"ox-dialer"'),
    ("camera-app-selftest/run", '"app":"Camera"', '"app":"ox-camera"'),
    ("wifi-selftest/run", '"app":"wifi.test"', '"app":"oxctl"'),
]


def main() -> int:
    bad = 0
    for fname, old, new in EDITS:
        p = SRC / fname
        text = p.read_text()
        n = text.count(old)
        if n == 0:
            if new in text:
                print(f"SKIP {fname}: already aligned ({new})")
                continue
            print(f"MISS {fname}: {old} not found")
            bad += 1
            continue
        p.write_text(text.replace(old, new))
        print(f"OK   {fname}: {old} x{n}")
    # wifi: the Settings panel consults as ox-settings — seed wifi.scan +
    # wifi.join grants for it after the last join-grant line.
    wf = SRC / "wifi-selftest/run"
    text = wf.read_text()
    if '"app":"ox-settings"' not in text:
        anchor = '{"app":"oxctl","permission":"wifi.join","mode":"grant"}\' >/dev/null 2>&1\n'
        add = (
            anchor
            + "    /usr/bin/oxctl permstored set '{\"app\":\"ox-settings\",\"permission\":\"wifi.scan\",\"mode\":\"grant\"}' >/dev/null 2>&1\n"
            + "    /usr/bin/oxctl permstored set '{\"app\":\"ox-settings\",\"permission\":\"wifi.join\",\"mode\":\"grant\"}' >/dev/null 2>&1\n"
        )
        if anchor in text:
            wf.write_text(text.replace(anchor, add, 1))
            print("OK   wifi-selftest/run: ox-settings panel grants added")
        else:
            print("MISS wifi-selftest/run: ox-settings anchor not found")
            bad += 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
