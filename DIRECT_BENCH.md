# Direct-Mode Benchmark Runbook

End-to-end recipe for running the May 2026 conditional-write sweep
**direct-mode only** (raw FileIO atomic ops; the `FileIOCatalog`
dimension is deferred). This is the operational complement to:

- [`YCSB_REFRESH.md`](YCSB_REFRESH.md) — design rationale and the full
  sweep matrix (direct + fileio).
- [`catalog-bench/README.md`](catalog-bench/README.md) — full
  `bench.sh` subcommand reference and configuration knobs.

This file restates only the parts specific to driving the direct-only
sweep on the `2026-05-refresh` branch.

## Status & scope

- Branch: `2026-05-refresh` on `YCSB`.
- Mode: `CLIENT=direct` only. `bench.env` ships with
  `SWEEP_CLIENTS="direct"` so `bench.sh sweep <cloud>` will not fan out
  into `fileio`. Re-add `fileio` when `FileIOCatalog` is ready.
- Smoke run: `gcp/std/CAS/direct` already passed end-to-end (commit
  `96d9dd5`); subsequent commits added the disconnect/reconnect support
  used below.

## Pre-flight (one-time per workstation)

```bash
# Cloud auth — only the clouds you'll target need to be live.
aws sso login                # or `aws configure` for static creds
az login
gcloud auth login && gcloud auth application-default login

# SSH key bench.sh expects (override per-cloud in bench.env if different):
ls ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.pub

# Toolchain on the workstation:
terraform -version           # >= 1.6
java -version                # 17
mvn -version
which gcloud aws az rsync ssh jq
```

Edit [`catalog-bench/bench.env`](catalog-bench/bench.env) only if your
workstation paths differ from the defaults
(`YCSB_TREE`, `ICEBERG_HOME`, `FILEIO_CATALOG_HOME`).

## Per-cloud first-time setup

`bench.sh init` is idempotent. The first run on each cloud handles the
`terraform import` of pre-existing resources documented in
[`YCSB_REFRESH.md` Phase A.3](YCSB_REFRESH.md#a3-each-infra--reproducibility-first).

### AWS

```bash
catalog-bench/bin/bench.sh init aws --apply
```

On first apply, `bench.sh init` runs
`terraform import aws_s3_directory_bucket.express
"lst-pbafvfgrapl--usw2-az3--x-s3"` to adopt the existing S3 Express
bucket, then applies. Re-runs are no-ops.

> The workstation IAM principal (typically a least-privileged user like
> `casuser`) needs IAM read perms on the role/policy/instance-profile,
> S3-Express read perms on the directory bucket, and IAM
> `CreatePolicyVersion`/`DeletePolicyVersion`/`SetDefaultPolicyVersion`
> write perms on `ycsb-s3-policy`.  See
> [`catalog-bench/aws/README.md`](catalog-bench/aws/README.md) for the
> exact policy JSON — an admin attaches it once.

### Azure

`bench.sh init azure` does **not** auto-import the Standard storage
account. First run prints the exact import command:

```bash
catalog-bench/bin/bench.sh init azure
# → prints e.g.:
#   terraform -chdir=catalog-bench/azure/infra import \
#     azurerm_storage_account.adls_standard \
#     "/subscriptions/<sub>/resourceGroups/<rg>/.../storageAccounts/lstnsgym"
```

Run the printed command with your subscription + RG, then:

```bash
catalog-bench/bin/bench.sh init azure --apply
```

This also regenerates SAS tokens (the ones in `azure/tokens/` are
stale from `20250609`). The SAS data sources renew on each apply, so
re-run `init azure --apply` whenever a stale-token error appears.

### GCP

```bash
catalog-bench/bin/bench.sh init gcp --apply
```

The Rapid bucket `lstx-consistency` was already imported during the
smoke session; `init` is a no-op against that state. Standard bucket
`lst-uw4-std` is created if missing.

## Direct-only sweep matrix

9 cells total (vs 22 for the full direct + fileio matrix):

| Cloud | Cell tag        | Tier               | Mode   | Notes |
|-------|-----------------|--------------------|--------|-------|
| AWS   | `aws/CAS`       | std (S3 Standard)  | CAS    | |
| AWS   | `awsx/CAS`      | x   (S3 Express)   | CAS    | |
| AWS   | `awsx/append`   | x   (S3 Express)   | append | |
| Azure | `azure/CAS`     | std (Blob Std)     | CAS    | |
| Azure | `azure/append`  | std (Blob Std)     | append | |
| Azure | `azurex/CAS`    | x   (Premium)      | CAS    | |
| Azure | `azurex/append` | x   (Premium)      | append | |
| GCP   | `gcp/CAS`       | std (GCS Std)      | CAS    | |
| GCP   | `gcprapid/CAS`  | rapid (Zonal)      | CAS    | |

Skipped (the underlying FileIO doesn't support APPEND):

- `aws/std/append` — S3 Standard has no append primitive.
- `gcp/std/append` — `GCSFileIO.supportsAppend()==false`.
- `gcprapid/append` — Rapid appendable-object protocol unsafe under
  contention; see
  [`iceberg/docs/docs/atomic_io_gcs_rapid.md`](../iceberg/docs/docs/atomic_io_gcs_rapid.md).

`bench.sh sweep <cloud>` already skips these combinations
automatically.

Per-cell budget: `SWEEP_THREAD_RANGE=1,2,4,8` (4 logarithmic counts) ×
`SWEEP_RUNS=5` × 5-min runs ≈ **1.7 hr/cell**. Sweep total ≈
**15 hr sequential** + ~10 min/cloud setup+destroy.

VMs are 8-core across all three clouds for parity:
`AWS_INSTANCE_TYPE=m5.2xlarge`, `AZURE_VM_SIZE=Standard_D8s_v3`,
`GCP_INSTANCE_TYPE=n2-standard-8`. Threads max=8 because
[Jan 2026 results](https://cdouglas.github.io/posts/2026/01/conditional)
showed conditional-write goodput plateaus at ~8 concurrent writers.
The 8-core sizing also keeps Azure within the default 10-core
sponsorship quota (no quota-increase request needed).

## Per-cloud sweep procedure

Identical shape on each cloud. Pick the cloud and go:

```bash
# One-time (skip if already done above):
catalog-bench/bin/bench.sh init <cloud> --apply

# All-in-one sweep:
catalog-bench/bin/bench.sh sweep <cloud>
```

`sweep` composes `up → setup → run × N → fetch → down`. Any step is
independently runnable if a sweep is interrupted — see the
[step-by-step block in README.md](catalog-bench/README.md#run).

## Disconnect / reconnect

`bench.sh run` launches `lst.sh` on the VM via `nohup`. The on-VM run
survives a workstation disconnect; only the local poll loop dies.

```bash
catalog-bench/bin/bench.sh status <cloud>   # current cell + last 10 log lines
catalog-bench/bin/bench.sh tail   <cloud>   # follow the live log
catalog-bench/bin/bench.sh wait   <cloud>   # resume blocking on the in-flight PID
catalog-bench/bin/bench.sh run    <cloud> --no-wait  # fire-and-forget
```

To kill an in-flight run: `ssh` to the VM and
`kill $(cat /YCSB/results/.bench.pid)`.

## Result handoff

After a sweep, results land at:

```
catalog-bench/results/<UTC-timestamp>/<cloud>/<CLOUD_TAG>_<VM>_direct_<MODE>_<AUTH>.tgz
```

Push them through the analysis pipeline:

```bash
cd ../YCSB-data
git checkout 2026-05-refresh
rsync -av ../YCSB/catalog-bench/results/<UTC-timestamp>/*/  ycsb-analysis/data/
cd ycsb-analysis && rm -rf cache/*
./venv/bin/python -m src.analyze_ycsb
```

Plots regenerate under `ycsb-analysis/figs/`.

## Known caveats

- **GCS per-object 1-update/sec throttle** — most ops on `gcp/CAS` and
  `gcprapid/CAS` will report as `FAILED`
  (`StorageThrottleException` → HTTP 429). Goodput is the
  `RawUPDATE-CAS` count, not the raw op count. Expected behavior, not
  a bug.
- **GCP region drift** — this run uses `us-west4-c`; the Jan 2026
  numbers are `us-west1`. Standard-GCS is not directly comparable
  across vintages. Call this out in any post that compares.
- **ADLS APPEND headline** — commit
  [`4d05ce037`](https://github.com/apache/iceberg/commit/4d05ce037)
  ("ADLS: serialize atomic append+flush with a blob lease") changed
  ADLS APPEND throughput at high concurrency. Eyeball the
  `azure/append` and `azurex/append` curves first when results land.
- **GCS Rapid CAS is currently broken** — `GCSAtomicOutputStream`
  uses `storage.blobWriteSession()` which defaults to resumable
  upload. Rapid Storage zonal buckets reject resumable uploads with
  HTTP 400 ("Zonal buckets are incompatible with resumable upload").
  Until `iceberg/gcp/.../GCSAtomicOutputStream.java` is fixed to use
  `BlobWriteSessionConfigs.bufferToTempDirThenUpload()` (or
  equivalent non-resumable single-shot upload) on zonal buckets, the
  `gcprapid/CAS` cell produces 0-throughput runs. The cell is left in
  the matrix as a placeholder.

## Cost

Direct-only sweep on 8-core VMs:

- ~9 cells × 1.7 hr = 15 cell-hours.
- Setup + destroy: ~30 min/cloud × 3 = ~1.5 hr.
- Total ≈ **17 VM-hours** × ~$0.40/hr blended (8-core)
  ≈ **~$7** in compute.
- Egress + storage: negligible.

Full direct + fileio matrix on 8-core would be ~$40 (22 cells × 1.7 hr).

## Outstanding TODOs

Carried forward from `YCSB_REFRESH.md` but not in scope for this
runbook:

- **Phase E delta analysis** —
  `YCSB-data/ycsb-analysis/src/delta_analysis.py` joining Jan 2026
  main-branch parquet against `2026-05-refresh` for a Jan-vs-May
  per-cell delta table + ADLS APPEND headline plot. Defer until data
  exists.
- **FileIOCatalog dimension** (`CLIENT=fileio`) — re-enable when the
  `FileIOCatalog` API is ready: edit `bench.env` to flip
  `SWEEP_CLIENTS="direct"` back to `"direct fileio"`.
- **Cloud-upload fallback in `lst.sh`** — belt-and-suspenders for
  flaky workstation rsync. Not implemented; rsync-only by design.
- **Pre-baked AMI** — saves the ~3–5 min apt install on each fresh VM.
  Worth it if we resume sweeping monthly.
