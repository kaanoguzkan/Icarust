# Icarust — Bug Fix Plan

Tracking doc for known bugs found while getting Icarust building/running on macOS
(2026-06-24). Check items off as fixed. See also `CLAUDE.md` for architecture.

## Environment / how to build + run (needed to verify fixes)

Native build on macOS (Apple Silicon, Homebrew). Three non-obvious setup steps:

```bash
# 1. Toolchain — MUST use hdf5@1.10 (plain `hdf5` is v2.x; old hdf5-sys 0.8.1 can't parse it)
brew install rust protobuf hdf5@1.10

# 2. Pin chrono — no Cargo.lock committed; default resolve breaks arrow-arith 49 (POD5 dep)
cargo update -p chrono --precise 0.4.31

# 3. Build + run (hdf5@1.10 is keg-only, so set these)
export HDF5_DIR="$(brew --prefix hdf5@1.10)"
export RUSTFLAGS="-C link-args=-Wl,-rpath,$HDF5_DIR/lib"
cargo build --release
export DYLD_FALLBACK_LIBRARY_PATH="$HDF5_DIR/lib"
./target/release/icarust -s Profile_tomls/config_dnar10.toml -v   # run from repo root
```

`(DNA,R10)`, `(DNA,R9)` and `(RNA,R9)` configs run (DNA+R9 fixed in #1). Only RNA+R10 is rejected (unsupported).

Client verification (no hardware needed — Icarust IS the simulated device):
`pip install minknow_api` in a venv, set `MINKNOW_TRUSTED_CA` to a ca.crt matching the
server cert (see bug #2), then `Manager(host="localhost", port=10000)` →
`flow_cell_positions()` → `.connect()` → `instance.get_version_info()`.
(Do NOT call `manager.describe_host()` until bug #3 is fixed.)

---

## 🔴 Critical — break basic usage

- [x] **#1 DNA+R9 panics at startup** — `src/main.rs:341-347` ✅ DONE
  - `sim_type` match has no `(DNA,R9)` arm → `panic!("We shouldn't be readig sequence for R10 RNA or R9DNA")`. `config_dnar9.toml` dies instantly. `get_sim_profile` (`src/simulation.rs:157`) has `DNAR9 => unimplemented!()`.
  - **Fix:** add `(DNA,R9) => SimType::DNAR9` arm + a real `SimSettings` for `DNAR9` (R9.4.1 digitisation/range/offset/scale — metadata only, signal is pre-digitised `.npy`).
  - **Done:** added arm in main.rs + `DNAR9` profile (digitisation=8192, range=1350, from make_squiggle.py) in simulation.rs; RNA+R10 now the only panicking combo. Verified `config_dnar9.toml` runs, reads flowing.

- [x] **#2 Committed TLS certs are a mismatched pair** — `static/tls_certs/` ✅ DONE
  - `server.crt` issued by `CN=LocalhostCA` but `ca.crt` is `CN=MyRootCA`; `openssl verify -CAfile ca.crt server.crt` FAILS → no client can handshake (broke in commit b9faa14). `server.crt` also has no SAN.
  - **Fix:** regenerate consistent CA + server cert with `subjectAltName=DNS:localhost,IP:127.0.0.1`; commit all three matching files.
  - **Done:** regenerated CA (`CN=Icarust Root CA`) + server cert with SAN (localhost,*.localhost,127.0.0.1,::1), 825-day validity; `openssl verify` OK. Verified Python client handshakes with repo `ca.crt`.

- [x] **#3 `manager.describe_host()` is `unimplemented!()`** — `src/impl_services/manager.rs:48-53` ✅ DONE
  - Calling it panics the handler → client gets RST_STREAM. Newer `minknow_api` calls it.
  - **Fix:** return a populated `DescribeHostResponse`.
  - **Done:** returns `DescribeHostResponse` (empty product_code = generic host, description "Icarust simulated host", network_name "localhost", can_sequence_offline true). Verified via client.

## 🟠 High — silent wrong behavior

- [x] **#4 Inconsistent default sample rate (4000 vs 5000)** — `src/main.rs:339` vs `src/main.rs:220` ✅ DONE
  - main.rs uses `sample_rate.unwrap_or(5000)` for the Device service; `Parameters::get_sample_rate()` uses `unwrap_or(4000)` everywhere else. Unset rate ⇒ device reports 5000 Hz while data is 4000 Hz.
  - **Fix:** use `get_sample_rate()` in main.rs (single source of truth).
  - **Done:** main.rs now calls `config.parameters.get_sample_rate()`. Verified: profile with no `sample_rate` → device reports 4000.

- [x] **#5 Manager advertises hardcoded position port** — `src/main.rs:357-360` ✅ DONE
  - `RpcPorts { secure: 10001, ... }` hardcoded, but position server binds `a_port` from `config.ini`. Changing the port ⇒ clients told to connect to 10001 (wrong).
  - **Fix:** `secure: a_port as u32` (field is `u32`, not `i32`).
  - **Done:** verified — config.ini position=10055 → manager advertises 10055, client connected to it.

- [ ] **#6 Read-length→samples scaling ignores `sequencing_speed`** — `src/main.rs:250-251`
  - `ReadLengthDist::new(mrl / 400.0 * sample_rate)` hardcodes 400, but signal uses `samples_per_base = sample_rate / sequencing_speed` (`src/impl_services/data.rs:1145`). With `sequencing_speed=450` (in `config_dnar9.toml`!) lengths disagree → wrong durations.
  - **Fix:** divide by `sequencing_speed`, not 400.

- [ ] **#7 Hardcoded 3000-element action arrays cap channels** — `src/impl_services/data.rs:616, 668`
  - `read_numbers_actioned: [0; 3000]` indexed by channel number; `channels > 3000` ⇒ index-out-of-bounds panic on unblock/stop-receiving.
  - **Fix:** size from `channel_size` (use a `Vec`).

## 🟡 Medium — edge cases / robustness

- [ ] **#8 Read start underflows on short references** — `src/impl_services/data.rs:1341`
  - `rng.gen_range(0..contig_len - 1000)` panics if `contig_len <= 1000` (small FASTAs, e.g. `ENO2.fa`/pico). `usize` underflow or `gen_range(0..0)`.
  - **Fix:** guard/clamp the floor against `contig_len`.

- [ ] **#9 Wall-clock `.time()` subtraction drops the date** — `src/impl_services/data.rs:487, 1671`
  - `unblock_time.time() - prev_time.time()` and `now_time.time() - previous_access_time.time()` use time-of-day only; across midnight/>24h goes negative → corrupts chunk slicing + unblock truncation.
  - **Fix:** subtract full `DateTime<Utc>` values.

- [ ] **#10 Blocking `thread::sleep` inside async task** — `src/impl_services/data.rs:1741`
  - Chunk-serving loop in `tokio::spawn` calls `std::thread::sleep(break_chunk_ms)`, blocking a tokio worker ~400ms/cycle.
  - **Fix:** `tokio::time::sleep(...).await`.

- [ ] **#11 Amplicon reads aren't full-length** — `src/impl_services/data.rs:1339-1347`
  - README says amplicon ⇒ complete file length, but `end = min(start + read_length, contig_len-1)` still truncates.
  - **Fix:** for amplicons set `end = contig_len - 1`.

- [ ] **#12 Data loss on graceful shutdown** — `src/impl_services/data.rs:453-600`
  - Shutdown drains at most 4000 reads then breaks; extras (and reads still in channel) dropped.
  - **Fix:** loop-drain all remaining reads before breaking.

## 🔵 Low — doc/behavior mismatches & cleanup

- [ ] **#13** `working_pore_percent` default is 90, README says 85 — `src/main.rs:98`.
- [ ] **#14** `pore_type` default is R10, README says R9 — `src/main.rs:111`.
- [ ] **#15** `convert_milliseconds_to_samples` does integer `sampling/1000` before float multiply — `src/impl_services/data.rs:1224`.
- [ ] **#16** `samples_since_start`/`seconds_since_start` always 0 in live-read responses — `src/impl_services/data.rs:1729-1730`.
- [ ] **#17** `_load_toml` parses the config file 3× (main, `DataServiceServicer::new`, write-out thread) — minor inefficiency.
- [ ] **#18** Dead/stub code: `RunSetup`, `action_responses`, `Acquisition` streams — not bugs, worth cleanup.

---

## Suggested sequencing

1. **PR 1 (correctness-critical, low-risk):** #1, #2, #3, #4, #5. Verify each against a live run + Python client.
2. **PR 2 (edge cases):** #6, #7, #8, #9, #10, #11, #12.
3. **PR 3 (cleanup):** #13-#18.
</content>
