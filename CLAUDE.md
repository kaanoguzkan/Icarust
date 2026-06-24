# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Icarust is a Rust-based simulator of Oxford Nanopore's MinKNOW sequencer. It hosts a facsimile of the MinKNOW gRPC API so that adaptive-sampling clients (primarily [readfish](examples/example_readfish.toml)) can be developed and tested against a deterministic, replayable signal source instead of real hardware. It generates and serves nanopore squiggle (raw current signal) and writes out FAST5 / POD5 files.

## Build, run, test

```bash
# Build (release strongly preferred — debug is far too slow to keep up with the data loop)
cargo run --release -- --help

# Run a simulation: -s = simulation profile TOML, -v = logging (none without -v!)
cargo run --release -- -s Profile_tomls/config_dnar9.toml -v

# Override the sequencer config.ini (ports / channels / TLS dir); default is ./config.ini
cargo run --release -- -s Profile_tomls/config_dnar10.toml -c config.ini -v

# Write POD5 instead of FAST5
cargo run --release -- -s Profile_tomls/config_dnar10.toml -p -v

# There is effectively no test suite — `cargo test` compiles but runs no real
# unit/integration tests. Verification is done by running against a client.
```

The binary **must be run from the repo root** (or a directory containing copies of `vbz_plugin/` and `static/`), because it loads the VBZ compression plugin and TLS certs by relative path.

### Build dependencies
- `protoc` **> 3.6.1** (Ubuntu 20.04's 3.6.1 fails with `--experimental_allow_proto3_optional`; see README issue #2).
- `libhdf5` for FAST5 support.
- The build compiles the `proto/minknow_api/*.proto` files via `build.rs` (tonic-build, client generation disabled).

### TLS / connecting clients
MinKNOW core 5.x requires a secure channel. Clients must point `MINKNOW_TRUSTED_CA` at `static/tls_certs/ca.crt`. The server loads `server.crt` / `server.key` from the `cert-dir` in `config.ini`. Certs live in [static/tls_certs/](static/tls_certs/) and expire periodically (see recent commits renewing them).

## Two layers of configuration

These are distinct and easy to confuse:

- **`config.ini`** (`-c`, defaults to `./config.ini`) — the *sequencer hardware* config: TLS cert dir, manager/position ports, and channel count. Parsed with `configparser` in [main.rs](src/main.rs).
- **simulation profile TOML** (`-s`, required) — the *experiment* config: samples, genomes/squiggle sources, read lengths, barcodes, pore type, yield. Deserialized via `toml` into the `Config` struct in [main.rs](src/main.rs). Examples in [Profile_tomls/](Profile_tomls/) and [examples/](examples/). The `Config`/`Parameters`/`Sample` structs and their `check_*`/`get_*` defaulting methods are the source of truth for valid fields and defaults.

## Architecture

The runtime is a tokio multi-thread runtime running **two gRPC servers**:

1. **Manager server** (port `manager`, default 10000/9502) — `impl_services/manager.rs`. A client queries it first to discover the sequencing position's name and port.
2. **Position server** (port `position`, default 10001) — hosts all the per-position services and is where the real work happens.

### Services
Each MinKNOW gRPC service is implemented as a module under [src/impl_services/](src/impl_services/) (declared in [src/impl_services.rs](src/impl_services.rs): acquisition, analysis_configuration, data, device, instance, log, manager, protocol). They implement the tonic-generated traits from [src/services.rs](src/services.rs), which `include_proto!`s every package under `minknow_api.*`. Most services return canned/hardcoded responses; **`data.rs` is the heart of the simulator** (~1800 lines).

### The data loop (impl_services/data.rs)
`DataServiceServicer::new` spawns three long-lived threads that stand in for the sequencer + MinKNOW. They coordinate over an `Arc<Mutex<Vec<ReadInfo>>>` (one `ReadInfo` per channel) plus tokio channels:

- **Data generation thread** (`thread::spawn` at the end of `DataServiceServicer::new`) — tight loop sleeping only 10ms per iteration. For any channel whose current read has run past its estimated finish time or was unblocked, it sends the finished read to the write-out thread, rolls a death chance (per [reacquisition_distribution.rs](src/reacquisition_distribution.rs), scaled to hit `target_yield`), and — with 75% probability — generates a new read via `generate_read`: draw a read length from a skewed F-distribution ([read_length_distribution.rs](src/read_length_distribution.rs), confusingly named but not a gamma), weighted-pick a sample then a squiggle file/contig, pick a random start, and copy signal into the channel's `ReadInfo`.
- **Process-actions thread** (`start_unblock_thread`, spawned per `get_live_reads` connection) — drains `GetLiveReadsRequest`s off a `SyncSender`, applies unblock (clears the read, marks `was_unblocked`) / stop-receiving / setup to the corresponding channel in the shared Vec.
- **Write-out thread** (`start_write_out_thread`) — receives finished reads and, every ~4000 reads (or on graceful shutdown), writes a FAST5 (via `frust5_api` + the VBZ plugin) or POD5 (via `podders`) file into `<output>/fast5_pass/`. Most FAST5/POD5 `tracking_id`/`context_tags` fields are hardcoded constants here.

Serving: `get_live_reads` is a bidirectional stream. The inbound half forwards each request to the process-actions thread; a separate spawned loop locks the shared Vec, works out how much signal has accrued per channel since `time_accessed` (using `sample_rate_hz`), and streams it back **split into chunks of 24 channels**, sleeping `break_read_ms` (default 400ms) between iterations — so `break_read_ms` is the *serving* cadence, not the generation cadence.

Shutdown is coordinated by an `Arc<Mutex<bool>>` (`graceful_shutdown`) set by the Ctrl-C handler in main.rs, by reaching `experiment_duration_set`, or when ~99% of pores are dead; threads then sleep ~10s and `process::exit`.

### Signal generation (simulation.rs)
`SimType` (DNAR10 / RNAR9) selects a `get_sim_profile` giving digitisation/range/offset/scale used to digitise signal and written into output files. For **R9** runs, `input_genome` points at pre-computed `.npy` squiggle arrays (generate them with `python/make_squiggle.py`, which also emits [distributions.json](distributions.json) weighting contigs by length). For **R10** (and RNA R9 with rna004), `input_genome` is a FASTA/FASTQ and signal is generated on the fly from the pore k-mer models in [static/](static/) (`dna_r10.4.1_e8.2_400bps`, `rna004`, etc.). Barcode squiggle from `static/barcode_squiggle` is optionally prepended per the sample's `barcodes`/`barcode_weights`.

## Notes

- `src/impl_services/` contains extra `.rs` files (e.g. `keystore.rs`, `minion_device.rs`, `rpc_options.rs`, `basecaller.rs`, `statistics.rs`, etc.) that are **not** declared in `impl_services.rs` and are not compiled — only the eight modules listed there are active.
- The crate enforces `#![deny(missing_docs)]` and `#![deny(missing_doc_code_examples)]`, so new public items need doc comments.
- Read lengths in config are in bases but internally scaled by `sample_rate / 400` (see `Sample::get_read_len_dist`).
- A Docker setup ([docker/](docker/)) and a separate [icarust_docker](https://github.com/looselab/icarust_docker) repo provide a no-build path; note macOS Docker volume I/O is slow.
