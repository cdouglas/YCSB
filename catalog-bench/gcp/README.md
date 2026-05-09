# GCP catalog-bench setup

Notes specific to driving the GCP sweep with `bench.sh`.  Generic
configuration lives in [`../README.md`](../README.md); this file covers
**only** the GCP-specific bootstrapping.

## Workstation prerequisites

`bench.sh init gcp --apply` and the per-cell `bench.sh up/run/...`
calls use Application Default Credentials.  Authenticate once:

```bash
gcloud auth login                         # for `gcloud` CLI use
gcloud auth application-default login     # for terraform / SDK use
gcloud config set project lst-consistency
```

The principal (typically your `@berkeley.edu` user) needs roles on
the `lst-consistency` project sufficient to:

- Create/destroy Compute VMs, networks, firewall rules
  (**`roles/compute.admin`**)
- Create / read / write GCS buckets
  (**`roles/storage.admin`**)
- Bind IAM on the benchmark service account
  (**`roles/iam.serviceAccountUser`** on
  `ycsb-benchmark-sa@lst-consistency.iam.gserviceaccount.com`,
  plus **`roles/resourcemanager.projectIamAdmin`** for
  `bench.sh init gcp --apply` to manage the project-level binding)

If you have `roles/owner` or `roles/editor` on the project, the
above are all included.

## Existing-resource adoption (Rapid bucket)

The Rapid Storage bucket `lstx-consistency` (zonal,
`storage_class = RAPID`, in `us-west4-c`) was created out-of-band as
part of the appendable-objects PoC and is too expensive to recreate.
`bench.sh init gcp` adopts it via `terraform import` automatically on
first run.  The Standard bucket `lst-uw4-std` is created from scratch.

If the import fails (e.g., the bucket was renamed), check the
canonical name in `bench.env` (`GCP_BUCKET_RAPID`) and the GCS
console.

## Region / zone

This sweep runs in **us-west4-c** (Las Vegas).  The Jan 2026 results
ran in us-west1; if you compare per-cell numbers across vintages, call
out the region change explicitly — network paths to client VMs differ.

## Known issue: Rapid `CAS` is currently broken

`GCSAtomicOutputStream` uses `storage.blobWriteSession()`, which
defaults to **resumable upload**.  Rapid Storage zonal buckets reject
resumable uploads with HTTP 400
(`"Zonal buckets are incompatible with resumable upload"`).  The
appendable-objects PoC commit `d6fd260bb` had a working CAS-replace
path on zonal via `storage.blobAppendableUpload(...)
.generationMatch(staleGen)`, but the entire commit was reverted in
`8ec6e0297`, including the working CAS path.  `gcprapid/CAS` runs
produce 0-throughput until that path is ported back into prod and
`google-cloud-storage` is bumped 2.55 → 2.68+.

`gcp/CAS` (Standard class, regional) works fine.  GCS doesn't have an
APPEND mode (zonal Rapid append is unsafe per
[`docs/atomic_io_gcs_rapid.md`](../../../iceberg/docs/docs/atomic_io_gcs_rapid.md);
non-zonal GCS has no append API).

## Other GCP-specific bootstrapping

- **VM image**: pinned in `gcp/benchmark/main.tf`; update if
  deprecated.
- **Service account `ycsb-benchmark-sa`**: created by `infra/`
  terraform with `roles/storage.objectAdmin`.  Each benchmark VM runs
  as this SA so the Java-side GCS reads/writes work without a key
  file (`AUTH=metal`).
- **VPC + firewall**: created in `benchmark/` (not `infra/`) — they're
  fast to recreate per sweep, and keeping them out of `infra/`
  avoids long-lived attack surface.
- **Quota**: the `n2-standard-8` VM consumes 8 vCPUs in the
  `us-west4-c` zone.  The default project quota is well above 8.  If
  you run multiple sweeps concurrently in the same zone, monitor
  `gcloud compute regions describe us-west4 --format='value(quotas)'`.
