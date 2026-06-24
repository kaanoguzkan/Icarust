# Icarust — Guide, Operations & Warnings

A practical guide to building, running, and operating this fork of **Icarust**, plus
a consolidated list of **warnings / gotchas** discovered while getting it working.

Icarust is a Rust simulator of Oxford Nanopore's MinKNOW sequencer. It hosts a
facsimile of the MinKNOW gRPC API so adaptive-sampling clients (primarily
**readfish**) can be developed and tested against a deterministic, replayable signal
source instead of real hardware. It generates nanopore squiggle (raw current) and
writes **FAST5** or **POD5** files. **You do not need any sequencing hardware — Icarust
*is* the simulated device; clients connect to it over localhost.**

---

## 1. Build & run

The binary **must be run from the repo root** (it loads `vbz_plugin/` and `static/`
by relative path).

> **TLS certs:** generated automatically. On first run Icarust creates a self-signed
> CA + `localhost` server cert in the `cert-dir` if none exist — nothing is committed
> and no manual step is needed. (A `static/tls_certs/generate_certs.sh` helper also
> exists if you ever want to (re)create them by hand.)

### Linux server (production target)

```bash
sudo apt update && sudo apt install -y protobuf-compiler libprotobuf-dev libhdf5-dev

cargo build --release
./target/release/icarust -s Profile_tomls/config_dnar10.toml -v      # FAST5 (default)
./target/release/icarust -s Profile_tomls/config_dnar10.toml -p -v   # POD5
```

On Linux, FAST5 works out of the box: the bundled VBZ plugin matches the platform and
`HDF5_PLUGIN_PATH` is now set automatically by the binary.

### macOS dev (Apple Silicon) — two non-obvious steps

```bash
# 1. Toolchain — MUST use hdf5@1.10 (Homebrew's default `hdf5` is v2.x; the old
#    hdf5-sys crate panics: "Invalid H5_VERSION: 2.1.1")
brew install rust protobuf hdf5@1.10

# 2. Build + run (hdf5@1.10 is keg-only). Cargo.lock is committed (pins chrono
#    0.4.31) so deps resolve correctly — no manual pin needed. Use a recent rust.
export HDF5_DIR="$(brew --prefix hdf5@1.10)"
export RUSTFLAGS="-C link-args=-Wl,-rpath,$HDF5_DIR/lib"
cargo build --release --locked
export DYLD_FALLBACK_LIBRARY_PATH="$HDF5_DIR/lib"
./target/release/icarust -s Profile_tomls/config_dnar10.toml -p -v   # use -p on Apple Silicon (see #FAST5 warning)
```

### CLI flags
`-s <profile.toml>` (required) · `-c <config.ini>` (default `./config.ini`) ·
`-p` write POD5 instead of FAST5 · `-v`/`-vv`/`-vvv` logging (nothing without `-v`).

---

## 2. Two layers of configuration (easy to confuse)

- **`config.ini`** (`-c`) — the *sequencer hardware*: TLS cert dir, manager/position
  ports, channel count.
- **simulation profile TOML** (`-s`) — the *experiment*: samples, genomes/squiggle,
  read lengths, barcodes, pore type, yield. Examples in `Profile_tomls/`.

Supported `(nucleotide, pore)` combinations:

| combo | input | signal source |
|---|---|---|
| DNA + R10 | FASTA/FASTQ | generated on the fly from k-mer models |
| DNA + R9  | pre-computed `.npy` squiggle (`python/make_squiggle.py`) | read directly |
| RNA + R9  | transcriptome FASTA | generated on the fly |
| **RNA + R10** | — | **NOT supported (rejected at startup)** |

---

## 3. Connecting a client (readfish / Python)

Icarust alone just serves gRPC on `:10000` (manager) and `:10001` (position) and logs
internally. To exercise it, point a MinKNOW-API client at localhost. MinKNOW core 5.x
requires TLS, so the client must trust the CA:

```python
import os
os.environ["MINKNOW_TRUSTED_CA"] = "/path/to/Icarust/static/tls_certs/ca.crt"
from minknow_api.manager import Manager
m = Manager(host="localhost", port=10000)          # port = config.ini [PORTS] manager
pos = next(m.flow_cell_positions())
con = pos.connect()
print(con.instance.get_version_info().minknow.full)
```

For readfish: `export MINKNOW_TRUSTED_CA=".../static/tls_certs/ca.crt"` before running it.

---

## 4. Docker (updated run)

The Docker image bundles all dependencies (no local toolchain needed) and works well on
**Linux**. On macOS, Docker volume I/O is slow (virtualisation) — prefer native there.

```bash
cd docker

# Build the image (picks up all source + the fixed TLS certs)
docker compose build

# Run with the default profile (config_dnar10_5khz.toml)
docker compose run icarust

# Run a specific profile / write POD5
docker compose run icarust -v -s /configs/config_dnar10.toml
docker compose run icarust -v -p -s /configs/config_dnar10.toml
```

`docker/docker-compose.yml` maps host ↔ container:
`./configs → /configs`, `./squiggle_arrs → /squiggle_arrs`, `./output → /tmp`, and
publishes ports `10000` and `10001`. The image generates its TLS certs at build time
(`cert-dir = /static/tls_certs/`). To connect a client running **outside** the
container, grab the CA it trusts:

```bash
docker cp "$(docker compose -f docker/docker-compose.yml ps -q icarust)":/static/tls_certs/ca.crt ./ca.crt
export MINKNOW_TRUSTED_CA="$PWD/ca.crt"
```

> Build note: the Dockerfile builds against the committed `Cargo.lock`
> (`cargo build --release --locked`) on `rust:1.96-bookworm`. If you build for an
> x86_64 host from an Apple-Silicon machine, add `--platform linux/amd64`.

**Verified end-to-end:** image builds, container generates reads, **FAST5 output
works in-container** (the arm64-Linux VBZ plugin loads — the bare-metal Apple-Silicon
limitation does not apply in Linux containers), files appear on `./output`, and a
Python/readfish client connects through the published ports over TLS.

---

## 5. ⚠️ Warnings & gotchas

1. **FAST5 on Apple Silicon doesn't write — use `-p` (POD5).** `vbz_plugin/` ships no
   arm64-macOS build (only Linux `.so`s, an x86_64 `.dylib`, a Windows `.dll`), so
   arm64 HDF5 can't load the VBZ filter. FAST5 writes now **degrade gracefully** (log
   an error, keep the simulator running) instead of crashing, but no FAST5 file is
   produced. POD5 is pure-Rust and unaffected. Linux/x86_64 is fine.

2. **`Cargo.lock` is committed** (this fork un-ignored it) and pins `chrono 0.4.31`.
   Without that pin a fresh resolve pulls `chrono 0.4.45`, which fails to compile
   `arrow-arith 49` (POD5 dep) with a `quarter()` ambiguity — so **build with
   `--locked`** and don't `cargo update` chrono past 0.4.31. The lock is format **v4**,
   so the toolchain must be **rust ≥ 1.78** (the Docker image uses `rust:1.96`).

3. **macOS needs `hdf5@1.10`, not `hdf5`.** Homebrew's current `hdf5` is v2.x and the
   old `hdf5-sys 0.8.1` (via the FAST5 dep) panics parsing the version.

4. **TLS certs are generated automatically, never committed.** On startup Icarust
   creates a self-consistent CA + `localhost` server cert (SAN `localhost`/`127.0.0.1`)
   in the `cert-dir` if they're missing — no manual step. The cert/key files are
   git-ignored so **no private key ever lands in the repo** (upstream committed a
   private key *and* a mismatched cert pair — both fixed here). Clients trust the
   generated `ca.crt`. A `generate_certs.sh` helper exists for manual (re)generation.

5. **Must run from the repo root** (relative paths to `vbz_plugin/` and `static/`).

6. **`RNA + R10` is rejected** at startup; **`DNA + R9`** requires pre-computed `.npy`
   squiggle (a FASTA with DNA+R9 will fail).

7. **`break_read_ms` (default 400) is the *serving* cadence, not generation.** The data
   thread loops every ~10ms; reads are streamed to clients every `break_read_ms`.

8. **`samples_since_start` / `seconds_since_start`** reported to clients are measured
   **since the live-reads stream started**, not since acquisition start (approximation).

9. **Logging is off without `-v`.**

---

## 6. Licensing & publishing (this fork)

Icarust is **MPL-2.0** (weak, file-level copyleft) by the Loose Lab; see `LICENSE.md`
and `CITATION.cff` (DOI `10.1101/2023.05.16.540986`). You may fork, modify, and publish
it as open source and as a Docker image. When you do:

- Keep `LICENSE.md` and notices; changes to existing MPL files stay MPL and must be
  source-available (a public fork satisfies this).
- Distributing the Docker image = distributing executable form → tell recipients where
  the source is (a line in the DockerHub description: *"Based on Icarust (MPL-2.0).
  Source: <your fork>."*).
- The license covers code, not the "Icarust" name — mark it clearly as a fork; don't
  imply the original authors endorse it.
- Keep crediting the original authors (`CITATION.cff`).

---

## 7. Fixes applied in this fork (vs upstream)

| # | Fix |
|---|---|
| 1 | `DNA+R9` no longer panics at startup (added sim profile + match arm) |
| 2 | Regenerated the mismatched TLS certs (consistent CA + SAN) |
| 3 | `manager.describe_host()` implemented (was `unimplemented!()` → RST_STREAM) |
| 4 | Single source of truth for default sample rate (was 4000 vs 5000) |
| 5 | Manager advertises the configured position port (was hardcoded 10001) |
| 6 | Read-length→samples scaling honours `sequencing_speed` (was hardcoded 400) |
| 7 | Per-channel action arrays sized from `channel_size` (was `[0;3000]` → panic >3000) |
| 8 | Guarded read-start underflow on short references |
| 9 | Elapsed-time uses full `DateTime` (was time-of-day; broke across midnight) |
| 10 | Async sleep in the serving loop (was blocking a tokio worker) |
| 11 | Amplicon reads span the whole squiggle file |
| 12 | Graceful shutdown drains *all* remaining reads (was dropping >4000) |
| 15 | `convert_milliseconds_to_samples` divides in floating point |
| 16 | `*_since_start` fields populated (were hardcoded 0) |
| 17 | Config parsed once and passed to the write thread (was re-read) |
| 19 | FAST5 write hardened: auto `HDF5_PLUGIN_PATH` + graceful degradation (no cascade crash) |

(#13/#14 were README default corrections; #18 was stub annotation.)
</content>
