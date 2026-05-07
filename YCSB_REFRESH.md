# YCSB Conditional-Write Benchmark — Refresh & Consolidation

## Context

The Jan 2026 conditional-write benchmark (`cdouglas.github.io/_posts/2026-01-30-conditional.md`) needs a refresh because:

1. **ADLS atomic APPEND was made correct** by serializing append+flush with an Azure blob lease (commit `4d05ce037`, 2026-05-05). The prior implementation could silently lose bytes under concurrent writers despite reporting success. The lease likely changes APPEND throughput at high concurrency — the headline new finding for the post update.
2. **GCS Rapid Storage (Zonal buckets)** is a new tier worth a CAS measurement. A PoC for atomic APPEND against Rapid was added then reverted (`8ec6e0297`) because the appendable-object protocol is single-writer and can silently drop bytes; CAS, however, should be substantially faster than standard GCS.
3. **Full `FileIOCatalog` dimension** — measuring the real catalog (now mature with `ProtoCatalogFormat`) on top of each storage config — was deferred from the Jan 2026 publication and should be restored.

This document also **consolidates** the toolchain. The current state has accreted multiple near-duplicate terraform dirs, an abandoned Docker path, manual edits to `workloads/lst` to switch CAS↔append, and scattered helper scripts. The refresh collapses all of that into one driver utility plus one infra+benchmark dir per cloud, locking in the "known-OK" paths from Jan 2026:

- All GCS tests run from **one VM in us-west4-c** (existing `lstx-consistency` Rapid bucket from the appendable-objects PoC is already there). Standard GCS gets a sibling bucket in the same region (loses strict region parity with Jan 2026; explicit caveat in the post).
- Azure runs use **SAS tokens** (auth sidecar bypassed in Jan 2026; per-JVM keys ≡ shared key per analysis-side merge of `sas`+`user`).
- Benchmarks run **on metal** (no Docker — Jan 2026 metal numbers are the published ones; the `_metal` suffix in result-dir names is from this).
- Cloud upload is replaced with **`scp` back to the workstation** because the existing upload path didn't work in all clouds.
- All cloud resources are under terraform; existing manually-created resources are adopted via `terraform import` so the setup is fully reproducible.

**Decisions confirmed with user:**
- Re-run all 5 prior storage configs + add GCS Rapid (full sweep, mixed-vintage results avoided).
- Restore full `FileIOCatalog` dimension on all 6 storage configs (full provider × dimension matrix).
- One VM per cloud; GCP VM in **us-west4-c** with both Std (new bucket) and Rapid (existing `lstx-consistency`) buckets.
- `bench.sh` is a single bash file, consistent with existing `lst.sh` / `yssh.sh` / `generate_sas_keys.sh`.
- Bring all infra under terraform (S3 Express, Azure Std SA, GCS Rapid bucket all imported into state).

## Target end state

A single command on the workstation drives a full sweep on one cloud:

```
bench.sh sweep aws       # AWS: S3 std + S3 Express, raw + catalog, CAS + append, threads 1..16, 5 trials
bench.sh sweep azure     # ADLS Std + Premium, raw + catalog, CAS + append
bench.sh sweep gcp       # GCS Std + Rapid (CAS only on Rapid), raw + catalog
```

Subcommands so each phase can be run independently and resumed:

```
bench.sh init   <cloud>            # apply infra terraform once (creates buckets/IAM/SAS scaffold; imports existing)
bench.sh up     <cloud>            # apply benchmark VM terraform (provisions the VM)
bench.sh setup  <cloud>            # rsync YCSB tree to VM, mvn package on VM
bench.sh run    <cloud> <args>     # run lst.sh with the given knobs (client/mode/tier/auth)
bench.sh fetch  <cloud> [<dir>]    # rsync result dirs back into ./results-<date>/
bench.sh down   <cloud>            # destroy the benchmark VM (infra survives)
bench.sh status <cloud>            # show whether infra/VM exist; cost guesstimate
```

`sweep` composes `up` → `setup` → `run` × N cells → `fetch` → `down`.

---

## Phase A — Consolidate the catalog-bench tree

### A.1 Delete dead/duplicate

| Path | Why delete |
|------|-----------|
| `aws/benchmark/` (the bit-rotted dir) | Predates ProtoCatalogFormat migration; superseded by canonical `aws/benchmark/` (rename of `benchmark-raw/`) |
| `aws/benchmark-raw2/` | Identical tfvars to `benchmark-raw/`; the S3-Express-vs-Standard distinction was code-side, not terraform-side |
| `azure/main.tf` (top-level) + siblings (`variables.tf`, `terraform.tfvars`, top-level `tfstate*`, `yssh.sh`) | Mis-named: it's a VM dir, but `azure/infra/` is the real infra |
| `azure/benchmark-raw-x/` | Replaced by single `azure/benchmark/` that hits both Std and Premium accounts via SAS-file selection |
| `gcp/main.tf` (top-level) + siblings | Same anti-pattern as Azure top-level; replaced by `gcp/infra/` + `gcp/benchmark/` |
| `gcp/benchmark-raw/` | Wrong region (us-west1); replaced by single `gcp/benchmark/` in us-west4-c |
| `gcp/benchmark-raw-rapid/` (created earlier this session) | Premature; folded into the consolidated `gcp/benchmark/` |
| `gcp/infra-rapid/` (created earlier this session) | Premature; folded into `gcp/infra/` |
| `Dockerfile` / docker-related env in any remaining tfvars (`docker_image=...`) and user_data `docker run` blocks | Metal path is canonical |
| `YCSB/mkimg.sh` | Docker image build script; unused on metal path |

### A.2 Final layout

```
catalog-bench/
├── bin/
│   └── bench.sh             # driver utility (NEW, bash)
├── bench.env                # per-cloud config (bucket names, regions, ssh user, sweep matrix)
├── README.md                # how to use bench.sh
├── aws/
│   ├── infra/               # KEEP+EXTEND: S3 std + S3 Express (imported) + IAM + instance profile
│   └── benchmark/           # RENAMED from benchmark-raw/, docker stripped
├── azure/
│   ├── infra/               # KEEP+EXTEND: RG + Std SA (imported) + Premium SA + SAS scaffold
│   ├── benchmark/           # RENAMED from benchmark-raw/, docker stripped, hits both Std + Premium
│   ├── generate_sas_keys.sh # KEEP
│   └── tokens/              # gitignored; populated by infra apply / generate_sas_keys.sh
└── gcp/
    ├── infra/               # NEW: SA + IAM + std bucket in us-west4 + Rapid bucket (imported)
    └── benchmark/           # NEW: single VM in us-west4-c, hits both std + Rapid
```

### A.3 Each `infra/` — reproducibility-first

Every resource a benchmark depends on is under terraform. Existing manually-created resources are adopted via `terraform import` rather than left out-of-band.

- **aws/infra/**:
  - S3 Standard bucket `lst-pbafvfgrapl` (already in tf).
  - S3 Express One Zone bucket `lst-pbafvfgrapl--usw2-az3--x-s3` — new `aws_s3_directory_bucket` resource, **adopted via `terraform import`**.
  - IAM role `ycsb-ec2-role` + policy + instance profile (already in tf; extend the policy `Resource` list to include the Express bucket ARN).
- **azure/infra/**:
  - RG, Premium SA, container, SAS scaffold (already in tf).
  - Standard SA `lstnsgym` — new `azurerm_storage_account` resource (`account_tier=Standard`, `account_kind=StorageV2`, `is_hns_enabled=true`), **adopted via `terraform import`**.
  - Extend the SAS scaffold to issue tokens against both SAs.
  - Add `terraform output` for the SAS-token JSON paths so `bench.sh setup azure` can scp them to the VM.
- **gcp/infra/** (new):
  - SA `ycsb-benchmark-sa` + IAM `roles/storage.objectAdmin`.
  - Standard-class bucket `lst-uw4-std` in `us-west4` (new resource).
  - Rapid Zonal bucket `lstx-consistency` (existing in `us-west4`) — declared as `google_storage_bucket` with `storage_class = "RAPID"` + `hierarchical_namespace { enabled = true }` (provider `google-beta`), **adopted via `terraform import`**.

**Import recipe** (executed by `bench.sh init <cloud>` with safety prompts):
```
# AWS
terraform -chdir=aws/infra import aws_s3_directory_bucket.express \
    "lst-pbafvfgrapl--usw2-az3--x-s3"
# Azure
terraform -chdir=azure/infra import azurerm_storage_account.adls_standard \
    "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/lstnsgym"
# GCP
terraform -chdir=gcp/infra import google_storage_bucket.rapid \
    "lstx-consistency"
```

The first `terraform plan` after each import must show **zero diff** for the imported resource. Any non-zero diff is investigated and the resource declaration corrected before any apply.

### A.4 Each `benchmark/` — one VM, no docker

- **aws/benchmark/**: m5.4xlarge, us-west-2, IAM role from infra. user_data installs `git`, `openjdk-17-jdk-headless`, `maven`, `jq`, `awscli`. SSH ingress from workstation IP.
- **azure/benchmark/**: Standard_D16s_v3, West US, system-assigned identity gets Storage Blob Data Contributor on both SAs. user_data installs the same toolchain.
- **gcp/benchmark/**: n2-standard-16, us-west4-c, SA from infra. user_data installs the same toolchain. VPC + firewall created here (cheaper to recreate per sweep).

### A.5 Result-flow

`lst.sh` (modified — see Phase B) tars per-cell results into `${OUTDIR}.tgz` on the VM. **No cloud upload.** `bench.sh fetch <cloud>` rsyncs `/mnt/results/` from the VM via SSH to `./results-<UTCdate>/`. Tarballs survive `bench.sh down` because they live on the workstation by then.

---

## Phase B — Centralize workload configuration

### B.1 `workloads/lst`

Strip the per-run hand-edit comments (`# Set to 0 for CAS test` etc.). The workload becomes a stable artifact; per-cell knobs come from `-p` overrides set by `lst.sh`.

### B.2 `bin/lst.sh`

Add four env vars:
- `MODE=cas|append` (default `cas`) → `-p fileio.max.log.size=0` for `cas`; default for `append`.
- `TIER=std|x|rapid` (default `std`) → selects bucket via `-p fileio.bucket=...`. Per-cloud mapping lives in `bench.env`.
- `AUTH=metal|sas` (default `metal` on AWS/GCP, `sas` on Azure) → on Azure, picks the SAS file template; reflected as result-dir suffix on others.
- `CLIENT=direct|fileio` (already exists) → maps to `-db site.ycsb.db.FileIOClient` (raw) or `FileIOCatalogClient` (catalog) via `bin/bindings.properties`.

`OUTDIR=${RESULTDIR}/${CLOUD_TAG}_${VM}_${CLIENT_TAG}_${MODE}_${AUTH}` produces the 5-token directory names the analysis pipeline already understands. No manual rename step.

`CLOUD_TAG`: `aws`/`awsx`/`azure`/`azurex`/`gcp`/`gcprapid` (encodes both cloud and tier). `CLIENT_TAG`: `direct` or `catalog`. `MODE`: `CAS` or `append`. `AUTH`: `metal` or `sas`.

### B.3 Drop the cloud-upload tail of `lst.sh`

Remove the `aws s3 cp` / `azcopy` / `gsutil cp` block and its bucket constants. Replace with a tarball at `/mnt/results/${OUTDIR}.tgz` plus a final `echo` of the path.

### B.4 `bench.sh` mechanics

Pseudocode for one cloud:

```bash
bench.sh sweep aws
  → terraform -chdir=aws/benchmark apply -auto-approve
  → rsync -az --delete /home/chris/work/catalog/YCSB/ ec2-user@VM:/YCSB/
  → ssh VM "cd /YCSB && mvn -pl :catalog-binding -am package -DskipTests"
  → for TIER in std x; do
      for CLIENT in direct fileio; do
        for MODE in cas append; do
          ssh VM "cd /YCSB && CLOUD=aws TIER=$TIER CLIENT=$CLIENT MODE=$MODE \
                  THREAD_RANGE=1..16 RUNS=5 ./bin/lst.sh"
        done
      done
    done
  → rsync -az ec2-user@VM:/mnt/results/ ./results-$(date -u +%Y-%m-%dT%H%M%SZ)/aws/
  → terraform -chdir=aws/benchmark destroy -auto-approve
```

Cell counts:
- AWS: 2 tiers × 2 clients × 2 modes = **8 cells**.
- Azure: 2 tiers × 2 clients × 2 modes = **8 cells**.
- GCP: (2 tiers × 2 clients × 2 modes) − 2 (rapid append unsafe) = **6 cells**.

Total: **22 cells** × ~5 thread-counts × 5 trials × 5-min runs ≈ ~110 cell-hours. Plus apply+setup+destroy overhead. Sequential per cloud → ~3–5 calendar days.

### B.5 `bench.env`

Single config file holds per-cloud bucket names per tier, region/zone/instance overrides, SSH user, and the sweep matrix. Editing this file changes the sweep without touching code.

---

## Phase C — Pre-flight tests (before first cloud apply)

1. **`mvn -f fileio-catalog/pom.xml test`** — ProtoCatalogFormat, action tests, commit-knob tests, inline-delta. ~1–2 min.
2. **`mvn -f iceberg/azure -pl :iceberg-azure test --tests "*ADLS*Append*"`** — exercises the new lease path. ~30 s. Critical because ADLS APPEND is the headline.
3. **`mvn -f /home/chris/work/catalog/YCSB/catalog/pom.xml package`** — re-confirm clean build after `lst.sh` changes.
4. **`bin/lst.sh --local`** with one cloud's dev creds, `THREAD_RANGE=1..1 RUNS=1 MODE=cas`. Exercises `gcprapid` branch, `ProtoCatalogFormat` ctor, `GoogleCredentials.fromStream`, the new env-driven `lst.sh`, the new `OUTDIR` naming.
5. **Single-VM smoke**: `bench.sh up gcp && bench.sh setup gcp && bench.sh run gcp --tier=rapid --client=direct --mode=cas --threads=1 --runs=1` end-to-end (~5 min). Verifies SSH/rsync, mvn-on-VM, Rapid bucket access, fetch path, destroy.

---

## Phase D — Run

```
bench.sh init aws azure gcp        # one-time (idempotent, includes imports)
bench.sh sweep aws                 # ~16 hr
bench.sh sweep azure               # ~16 hr  (re-runs the ADLS lease delta)
bench.sh sweep gcp                 # ~12 hr
```

Pull results into `YCSB-data/ycsb-analysis/data/` on branch `2026-05-refresh`, regenerate parquet + plots:

```
cd YCSB-data && git checkout 2026-05-refresh
rsync -av <workstation>/results-<date>/*/  ycsb-analysis/data/
cd ycsb-analysis && rm -rf cache/* && ./venv/bin/python -m src.analyze_ycsb
```

---

## Phase E — Cross-vintage delta tooling (stretch)

Add to `YCSB-data/ycsb-analysis/src/`:
- `delta_analysis.py`: joins committed Jan 2026 parquet (in main-branch git history) with new parquet from `2026-05-refresh` on `(provider, tier, dimension, threads, mode)`; outputs a per-cell delta table.
- One new plot: ADLS APPEND throughput Jan vs. May at 1/2/4/8/16 threads. Headline.

Defer until data exists.

---

## Critical files

**Driver (new)**
- `catalog-bench/bin/bench.sh`
- `catalog-bench/bench.env`

**Terraform (consolidated)**
- `catalog-bench/aws/infra/main.tf` (existing — extend to bring S3 Express bucket under terraform; import)
- `catalog-bench/aws/benchmark/` (renamed from `benchmark-raw/`; docker stripped)
- `catalog-bench/azure/infra/main.tf` (existing — extend to bring Std SA under terraform; import; output SAS file paths)
- `catalog-bench/azure/benchmark/` (renamed from `benchmark-raw/`; docker stripped; hits Std + Premium)
- `catalog-bench/gcp/infra/main.tf` (new — std bucket in us-west4 + Rapid bucket via import)
- `catalog-bench/gcp/benchmark/` (new — single VM in us-west4-c)

**Workload / driver scripts**
- `YCSB/workloads/lst` (strip hand-edit comments)
- `YCSB/bin/lst.sh` (accept MODE/TIER/AUTH/CLIENT env; new OUTDIR; drop cloud-upload tail)

**Already done in this session**
- `YCSB/catalog/pom.xml` and `FileIOClient.java` / `FileIOCatalogClient.java` migrations.
- `YCSB-data` branch `2026-05-refresh` analysis updates.

---

## Risks & verifications

- **GCP region drift**: us-west4-c ≠ Jan 2026's us-west1. Standard-GCS new vs. Jan 2026 numbers will not be directly comparable (network path differs). Mitigation: include "us-west4 vs us-west1" caveat in the post; if standard-GCS numbers shift more than expected, run a one-off control in us-west1 to confirm regional vs. protocol cause.
- **Existing tfstate files**: most current dirs have on-disk tfstate referencing real buckets/SAs. Renaming dirs without `terraform state mv` would orphan resources. Plan: `terraform state list` before any move, `terraform state mv` when needed; never delete a tfstate without confirming the underlying resource is intentional.
- **Idempotency on infra**: `bench.sh init <cloud>` must be safe to re-run. Terraform handles this once resource addresses are stable. Document idempotency.
- **Import-then-plan-then-apply discipline**: `terraform import` only writes state; the resource block in HCL must match reality, or the next plan will propose destructive changes. `bench.sh init` enforces a `plan` step that fails if the diff for an imported resource is non-empty.
- **SSH access lifecycle**: between `bench.sh up` and `bench.sh setup` the VM is booting. `setup` retries `ssh` with backoff.
- **mvn-on-VM bootstrap**: first `setup` builds against an empty `~/.m2`; ~3–5 min download. Acceptable. Pre-baking an AMI is a follow-up if it bites.
- **Cost**: ~110 cell-hours + setup/destroy ≈ 130 VM-hours. m5.4xlarge $0.77/hr, D16s_v3 ~$0.77/hr, n2-standard-16 ~$0.94/hr. ~$110 in compute total. Egress/storage negligible.

---

## Verification at the end

1. `bench.sh status <cloud>` reports infra applied, VM not present (after a sweep).
2. `results-<date>/<cloud>/` directories on the workstation contain expected `_metal`/`_sas`-suffixed dirs with `_raw` files inside.
3. `analyze_ycsb` regenerates plots with the new `gcprapid` palette and updated ADLS series.
4. Diff against Jan 2026 plots (committed on `YCSB-data` `main`) shows the expected ADLS-APPEND delta + new GCS-Rapid CAS series.
5. The new `bench.sh sweep <cloud>` is a single command that completes a full sweep without manual intervention (modulo cloud creds being fresh).
