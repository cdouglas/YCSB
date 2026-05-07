# catalog-bench

Multi-cloud sweep of the YCSB conditional-write workload, driven by a single
script: `bin/bench.sh`. One VM per cloud, all storage tiers exercised by
varying `fileio.bucket` at run time.

For the design and the May 2026 refresh context, see
[`../YCSB_REFRESH.md`](../YCSB_REFRESH.md).

## Prerequisites

- `terraform >= 1.6`, `gcloud`, `aws` CLI, `azure-cli`, `rsync`, `ssh`, `jq`
- Authenticated cloud sessions (`aws sso login`, `gcloud auth login`,
  `az login` — whichever clouds you'll target)
- `~/.ssh/id_ed25519{,.pub}` (or edit `AWS_SSH_PRIVATE_KEY` in `bench.env`)
- Iceberg + fileio-catalog SNAPSHOTs published locally:
  ```bash
  cd ../iceberg && ./gradlew publishToMavenLocal -x test -x integrationTest -x generateGitProperties
  cd ../fileio-catalog && mvn -DskipTests install
  ```

## Configure

Edit [`bench.env`](bench.env). One-liner per knob you'd actually change:

| Knob | Default | Purpose |
|------|---------|---------|
| `AWS_BUCKET_STD`, `AWS_BUCKET_X` | `lst-pbafvfgrapl`, `lst-pbafvfgrapl--usw2-az3--x-s3` | S3 Standard, S3 Express buckets |
| `AZURE_BUCKET_STD`, `AZURE_BUCKET_X` | `lstnsgym/...`, `lstnsgymx3serug/...` | ADLS Standard, Premium account+container |
| `GCP_BUCKET_STD`, `GCP_BUCKET_RAPID` | `lst-uw4-std`, `lstx-consistency` | GCS Standard (us-west4), Rapid Zonal (us-west4-c) |
| `SWEEP_<CLOUD>_TIERS` | per-cloud | Which tiers to sweep |
| `SWEEP_CLIENTS` | `direct fileio` | Raw FileIO and/or full FileIOCatalog |
| `SWEEP_MODES` | `cas append` | Workload modes |
| `SWEEP_THREAD_RANGE`, `SWEEP_RUNS` | `1..16`, `5` | Concurrency sweep, trials per cell |

Per-cloud bootstrap:

- **AWS**: existing S3 Express bucket is adopted via `terraform import` on
  first `bench.sh init aws`. The IAM role gets `s3express:CreateSession` on
  it.
- **Azure**: the Standard SA `lstnsgym` is adopted via `terraform import` —
  on first `bench.sh init azure` the script prints the exact import command
  with placeholders for subscription and RG; run it, then re-run `init`.
  SAS tokens for both Std and Premium SAs come from `terraform output`;
  copied onto the VM by `bench.sh setup azure`.
- **GCP**: the existing Rapid bucket `lstx-consistency` (us-west4-c, from
  the appendable-objects PoC) is auto-imported. The Standard bucket
  `lst-uw4-std` is created fresh.

## Run

```bash
# 1. one-time, idempotent: provisions buckets/IAM/SAS scaffold
bin/bench.sh init gcp --apply

# 2. all-in-one sweep on a cloud (provisions VM, sets up YCSB,
#    runs the matrix, rsyncs results back, destroys VM)
bin/bench.sh sweep gcp
```

Or step-by-step (each step is independent and resumable):

```bash
bin/bench.sh up    gcp                      # provision the VM
bin/bench.sh setup gcp                      # rsync YCSB tree, mvn package on VM
bin/bench.sh run   gcp --tier=rapid --client=direct --mode=cas
bin/bench.sh fetch gcp                      # rsync /mnt/results/ → ./results/<UTC>/gcp/
bin/bench.sh down  gcp                      # destroy the VM
```

Result tarballs land at:
```
catalog-bench/results/<UTC-timestamp>/<cloud>/<CLOUD_TAG>_<VM>_<CLIENT_TAG>_<MODE>_<AUTH>.tgz
```
e.g. `awsx_m5-4xlarge_direct_CAS_metal.tgz`. The 5-token directory naming is
what the analysis pipeline at `../../YCSB-data/ycsb-analysis/` expects.

## Sweep matrix

`bench.sh sweep` iterates the cross product `tiers × clients × modes` for the
given cloud, skipping combinations the underlying FileIO doesn't support.

`CLIENT` selects the **dimension** of the benchmark:
- **`direct`** — raw FileIO atomic ops (`FileIOClient.java`). Measures the
  cost of a single `CAS` or `APPEND` round-trip against the storage backend.
- **`fileio`** — full `FileIOCatalog` over FileIO (`FileIOCatalogClient.java`).
  Measures end-to-end multi-table catalog operations (`ProtoCatalogFormat`,
  inline mode, log compaction) layered on the same atomic primitives.

`MODE`-vs-`TIER` support matrix:

| Cloud | Tier | CAS | APPEND | Why APPEND is skipped (when it is) |
|-------|------|-----|--------|------------------------------------|
| AWS   | std (S3 Standard) | ✓ | — | Not measured in Jan 2026 |
| AWS   | x (S3 Express One Zone) | ✓ | ✓ | |
| Azure | std (Blob Standard) | ✓ | ✓ | |
| Azure | x (Premium BlockBlob) | ✓ | ✓ | |
| GCP   | std (GCS Standard) | ✓ | — | `GCSFileIO.supportsAppend()==false`; objects are immutable |
| GCP   | rapid (Rapid Zonal) | ✓ | — | Rapid appendable-object protocol is unsafe under contention; see `../iceberg/docs/docs/atomic_io_gcs_rapid.md` |

With `SWEEP_CLIENTS="direct fileio"`, cells per cloud:

| Cloud | Cells | Breakdown |
|-------|-------|-----------|
| AWS   | 6 | std×CAS, x×CAS, x×APPEND — each × 2 clients |
| Azure | 8 | std×CAS, std×APPEND, x×CAS, x×APPEND — each × 2 clients |
| GCP   | 4 | std×CAS, rapid×CAS — each × 2 clients |

Each cell does 5 thread counts × 5 trials × 5-min runs ≈ 2 hr of run time
plus per-cloud setup/destroy overhead.

## Tear down

```bash
bin/bench.sh down     <cloud>             # VM only (infra survives — for repeat sweeps)
bin/bench.sh teardown <cloud>             # destroys buckets + IAM + SAS scaffold (DELETES DATA)
                                          # prompts "Type 'destroy <cloud>' to proceed"
                                          # add --yes to skip the prompt
rm -rf catalog-bench/results              # workstation tarballs (manual, intentional)
```

## Status

```bash
bin/bench.sh status <cloud>               # what infra/VM exists right now
```

## Layout

```
catalog-bench/
├── bench.env          # per-cloud configuration
├── bin/bench.sh       # the driver
├── aws/{infra,benchmark}/
├── azure/{infra,benchmark}/
└── gcp/{infra,benchmark}/
```

`infra/` is created once per cloud and survives sweeps. `benchmark/` is the
VM, created and destroyed by each sweep. Both layers have their own
`tfstate`; `infra/` resources are the long-lived ones.

## Workload knobs

`workloads/lst` is a stable artifact; do not hand-edit to switch modes.
The `MODE` env var (passed by `bench.sh run`) selects between CAS and
append by setting `-p fileio.max.log.size=0` (cas) or letting the workload
default of 16 MiB stand (append). 256-byte deltas, 2 KiB base file,
`maxexecutiontime=300`, `fileio.max.attempts=1` (no retry/backoff —
upper-bound throughput), all match the Jan 2026 methodology.

## Troubleshooting

- **`init` refused to apply** — your plan would destroy or replace
  something. Run the printed `terraform … show <plan>` to see what; an
  imported resource block that doesn't match reality is the usual cause.
- **SSH never came up after `up`** — check the VM image / cloud quota; the
  retry loop gives up after ~5 min.
- **Azure SAS tokens stale** — re-run `bin/bench.sh init azure --apply` to
  regenerate (the SAS data sources renew on each `apply`).
- **Build fails on the VM** — `bench.sh setup` does `mvn -pl :catalog-binding -am package`; first run downloads the dependency closure (~3-5 min). If it errors, `ssh` to the VM and inspect `~/.m2`.
