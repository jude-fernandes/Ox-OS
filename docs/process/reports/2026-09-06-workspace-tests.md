# Workspace unit-test gate — tests that actually run

Date: 2026-09-06
Status: **DONE — WORKSPACE TEST GATE ALL GREEN** (128 tests, 0 failed;
verdict at bottom)

## Scope

Phase 3 chunk 17: the lesson from the grants-panel chunk (an
action-code/index swap shipped because unit tests don't run in the Nix
build) became a permanent gate.

- **`workspace-test` derivation** — runs `cargo test --release
  --locked --offline --workspace` on the HOST toolchain (same 1.82.0
  pin) inside the Nix sandbox, against the same vendored dependency
  set as the guest cross-build (the vendor dir was hoisted so both
  derivations share it). No network, no pip, no new dependencies.
- **`tools/test-gate.sh`** — builds the derivation; green only when
  every crate's test binary reports ok.

## What the first executions caught

The gate paid for itself immediately — four layers of never-executed
test code plus one real security bug:

1. **ox-ui's tests never compiled** — four
   temporary-dropped-while-borrowed errors (`s.ops_payload()["ops"]`
   chains). The guest build compiles the lib without tests, so this
   rotted invisibly. Fixed by binding the payload first.
2. **oxcom's click routing was untestable without gui** — the pointer
   module was cfg-gated while `handle`/`handle_input_wait` referenced
   `pointer::ClickHub` unconditionally. The module is now
   unconditional with a cfg-split `Display` alias, so the input-routing
   logic (and the two-client starvation regression test) is compiled
   and run on every test pass.
3. **Test rot from refactors** — `hit_app` grew a parameter its tests
   didn't get; oxresourced's helper used `?` in a tuple-returning
   function; ox-status's tile filter counted the top bar (h=120 at
   15% of 800); oxnetd's test helper unwrap-panicked on the exact
   empty-name case it was asserting `is_none` for; ox-settings's
   grants-panel tests destructured the old 4-button tuple, and one
   assertion compared row height against the footer's X axis.
4. **A real sandbox escape in ox-files** — `path_allowed` accepted
   `/data/ox2/steal` because `starts_with("/data/ox")` ignores the
   boundary. Fixed with a boundary check; the test that caught it
   (`traversal_outside_the_root_is_refused`) was written blind in the
   Files chunk and had never executed.

## Gate

`tools/test-gate.sh` → `nix build .#workspace-test`. **128 tests
passing, 0 failed**, across oxcom, ox-shell, ox-settings, ox-files,
ox-term, ox-intentd, ox-lockd, oxnetd, oxresourced, oxthermald,
permstored, notifd, ox-pay-proto, ox-ipc, ox-ui, ox-status.

## Honest limits

- The gate runs on every manual chunk from now on, but it is not yet
  wired into the payload derivation (a failing test would not block a
  payload build run by itself) — wiring it as a flake `check` closure
  dependency is the follow-up.
- ox-hello and oxpkg have no unit tests yet (thin IPC/CLI wrappers;
  their behavior is gate-covered on-device).
- Doctests are included in the run but sparse.

## Verdict

**WORKSPACE TEST GATE ALL GREEN** (2026-09-06): the whole workspace's
unit suite runs hermetically on every invocation — and its first
executions caught a real path-sandbox escape plus five layers of test
rot. This is the gate that keeps every future chunk honest.

## Addendum — wired into the payload (same day)

The "not yet wired into the payload" limit is closed: the rootfs
derivation references the workspace-test output (`test -f`), so nix
must build and pass the whole suite before the rootfs — and therefore
the payload and EVERY gate run. Proven by construction and by a
break/revert drill: a deliberately failing ox-lockd assertion blocked
the payload build (the log shows the exact test failure), and reverting
restored the build to the same store path. A failing unit test now
stops all downstream progress by default. CI wiring (same day): the
flake gained a `checks` output referencing the suite, so the standard
`nix flake check` validates and builds it alongside every other
output — any CI system gets the 128-test gate for free.
