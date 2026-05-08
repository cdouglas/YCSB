#!/usr/bin/env bash
set -euo pipefail

# bench.sh — single driver for the YCSB conditional-write benchmark refresh.
#
# Usage:
#   bench.sh init     <cloud> [--apply]    apply infra terraform once (idempotent; runs imports)
#   bench.sh up       <cloud>              apply benchmark VM terraform
#   bench.sh setup    <cloud> [--no-build]  build SNAPSHOTs + binding locally, rsync to VM
#   bench.sh run      <cloud> [opts]       run one cell via lst.sh on the VM
#   bench.sh fetch    <cloud> [<dest>]     rsync /mnt/results/ from VM into ${RESULTS_ROOT}/<date>/
#   bench.sh down     <cloud>              terraform destroy the VM (infra survives)
#   bench.sh teardown <cloud> [--yes]      terraform destroy the infra (buckets, IAM, SAS) — DESTROYS DATA
#   bench.sh status   <cloud>              show whether infra/VM exist
#   bench.sh sweep    <cloud>              up + setup + run (matrix from bench.env) + fetch + down
#
# `run` opts (env or --flag):
#   TIER   --tier=std|x|rapid     default: first entry of SWEEP_<CLOUD>_TIERS
#   CLIENT --client=direct|fileio default: direct
#   MODE   --mode=cas|append      default: cas
#   THREAD_RANGE --threads=A..B   default: SWEEP_THREAD_RANGE
#   RUNS   --runs=N               default: SWEEP_RUNS
#
# Reads catalog-bench/bench.env for per-cloud config.  All cloud uploads are
# disabled — results return via SSH rsync.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BENCH_ENV="${BENCH_ENV:-$REPO_ROOT/bench.env}"

if [[ ! -f "$BENCH_ENV" ]]; then
  echo "❌ bench.env not found at $BENCH_ENV" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$BENCH_ENV"

usage() {
  sed -n '3,32p' "$0"
  exit "${1:-0}"
}

require() {
  local v="$1"
  if [[ -z "${!v:-}" ]]; then
    echo "❌ Required env var $v is not set." >&2
    exit 1
  fi
}

# === Per-cloud accessors ===
infra_dir()     { echo "$REPO_ROOT/$1/infra"; }
benchmark_dir() { echo "$REPO_ROOT/$1/benchmark"; }

cloud_ssh_user() {
  case "$1" in
    aws)   echo "$AWS_SSH_USER" ;;
    azure) echo "$AZURE_SSH_USER" ;;
    gcp)   echo "$GCP_SSH_USER" ;;
    *) echo "❌ unknown cloud: $1" >&2; exit 1 ;;
  esac
}

cloud_bucket_for_tier() {
  local cloud="$1" tier="$2"
  case "$cloud,$tier" in
    aws,std)   echo "$AWS_BUCKET_STD" ;;
    aws,x)     echo "$AWS_BUCKET_X" ;;
    azure,std) echo "$AZURE_BUCKET_STD" ;;
    azure,x)   echo "$AZURE_BUCKET_X" ;;
    gcp,std)   echo "$GCP_BUCKET_STD" ;;
    gcp,rapid) echo "$GCP_BUCKET_RAPID" ;;
    *) echo "❌ no bucket configured for $cloud/$tier" >&2; exit 1 ;;
  esac
}

cloud_tiers() {
  case "$1" in
    aws)   echo "$SWEEP_AWS_TIERS" ;;
    azure) echo "$SWEEP_AZURE_TIERS" ;;
    gcp)   echo "$SWEEP_GCP_TIERS" ;;
  esac
}

# Reach the VM provisioned by the benchmark/ terraform dir.
vm_host() {
  local cloud="$1"
  terraform -chdir="$(benchmark_dir "$cloud")" output -raw vm_ip
}

ssh_to() {
  local cloud="$1"; shift
  local user host
  user=$(cloud_ssh_user "$cloud")
  host=$(vm_host "$cloud")
  ssh -o StrictHostKeyChecking=accept-new -i "$AWS_SSH_PRIVATE_KEY" "$user@$host" "$@"
}

rsync_to() {
  local cloud="$1" src="$2" dest="$3"
  local user host
  user=$(cloud_ssh_user "$cloud")
  host=$(vm_host "$cloud")
  rsync -az --delete \
    -e "ssh -o StrictHostKeyChecking=accept-new -i $AWS_SSH_PRIVATE_KEY" \
    "$src" "$user@$host:$dest"
}

rsync_from() {
  local cloud="$1" src="$2" dest="$3"
  local user host
  user=$(cloud_ssh_user "$cloud")
  host=$(vm_host "$cloud")
  rsync -az \
    -e "ssh -o StrictHostKeyChecking=accept-new -i $AWS_SSH_PRIVATE_KEY" \
    "$user@$host:$src" "$dest"
}

# === Subcommands ===

cmd_init() {
  local cloud="$1"; shift || true
  local apply=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --apply|-y) apply=true ;;
      *) echo "❌ unknown opt: $1"; exit 1 ;;
    esac
    shift
  done
  local dir; dir=$(infra_dir "$cloud")
  echo "==> terraform init in $dir"
  terraform -chdir="$dir" init -upgrade -input=false

  # Imports.  Each runs only if the resource is not already in state.
  case "$cloud" in
    aws)
      if ! terraform -chdir="$dir" state list 2>/dev/null | grep -q '^aws_s3_directory_bucket\.express$'; then
        echo "==> importing existing S3 Express bucket"
        terraform -chdir="$dir" import aws_s3_directory_bucket.express \
          "${AWS_BUCKET_X}" || true
      fi
      ;;
    azure)
      if ! terraform -chdir="$dir" state list 2>/dev/null | grep -q '^azurerm_storage_account\.adls_standard$'; then
        echo "==> import the existing Standard SA via:"
        echo "    terraform -chdir=$dir import azurerm_storage_account.adls_standard \\"
        echo "        '/subscriptions/<SUB>/resourceGroups/<RG>/providers/Microsoft.Storage/storageAccounts/lstnsgym'"
        echo "    Run that with the right subscription and RG, then re-run bench.sh init azure."
      fi
      ;;
    gcp)
      if ! terraform -chdir="$dir" state list 2>/dev/null | grep -q '^google_storage_bucket\.rapid$'; then
        echo "==> importing existing Rapid bucket"
        terraform -chdir="$dir" import google_storage_bucket.rapid "${GCP_BUCKET_RAPID}" || true
      fi
      ;;
  esac

  echo "==> terraform plan"
  local planfile; planfile=$(mktemp)
  terraform -chdir="$dir" plan -input=false -out="$planfile"

  # Refuse to apply if the plan would destroy any resources (catches a bad import).
  if terraform -chdir="$dir" show -json "$planfile" \
       | grep -q '"actions":\["delete"\]\|"actions":\["delete","create"\]'; then
    echo "❌ Plan would destroy or replace resources — refusing to apply." >&2
    echo "   Inspect with: terraform -chdir=$dir show $planfile" >&2
    rm -f "$planfile"
    return 1
  fi

  if [[ "$apply" == "true" ]]; then
    echo "==> terraform apply"
    terraform -chdir="$dir" apply -input=false "$planfile"
  else
    echo "==> Plan looks safe (adds/in-place-updates only).  To apply:"
    echo "    bench.sh init $cloud --apply"
    echo "    OR: terraform -chdir=$dir apply $planfile"
  fi
  rm -f "$planfile"
}

cmd_teardown() {
  local cloud="$1"; shift || true
  local yes=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y) yes=true ;;
      *) echo "❌ unknown opt: $1"; exit 1 ;;
    esac
    shift
  done
  local dir; dir=$(infra_dir "$cloud")
  echo "⚠️  This will destroy infra at $dir, including buckets and their data."
  if [[ "$yes" != "true" ]]; then
    read -r -p "Type 'destroy $cloud' to proceed: " confirm
    if [[ "$confirm" != "destroy $cloud" ]]; then
      echo "aborted."
      return 1
    fi
  fi
  terraform -chdir="$dir" destroy -auto-approve -input=false
}

cmd_up() {
  local cloud="$1"
  local dir; dir=$(benchmark_dir "$cloud")
  terraform -chdir="$dir" init -upgrade -input=false
  terraform -chdir="$dir" apply -auto-approve -input=false
  # Wait for SSH to come up.
  local host; host=$(vm_host "$cloud")
  echo "==> waiting for SSH on $host"
  for _ in $(seq 1 60); do
    if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
         -i "$AWS_SSH_PRIVATE_KEY" "$(cloud_ssh_user "$cloud")@$host" true 2>/dev/null; then
      echo "==> VM ready."
      return 0
    fi
    sleep 5
  done
  echo "❌ SSH never came up on $host" >&2
  return 1
}

cmd_setup() {
  local cloud="$1"; shift || true
  local build=true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-build) build=false ;;
      *) echo "❌ unknown opt: $1"; exit 1 ;;
    esac
    shift
  done

  if [[ "$build" == "true" ]]; then
    # Build the full closure on the workstation, where the SNAPSHOT artifacts
    # live in ~/.m2.  The catalog-binding assembly produces a self-contained
    # ~250 MB tarball at catalog/target/ycsb-catalog-binding-*.tar.gz that
    # ships every JAR the VM needs (core, catalog-binding, all iceberg
    # 1.11.0-SNAPSHOT jars).  Each step is idempotent.
    echo "==> publishing iceberg SNAPSHOTs to ~/.m2"
    ( cd "$ICEBERG_HOME" && \
      ./gradlew publishToMavenLocal \
        -x test -x integrationTest -x generateGitProperties )
    echo "==> installing fileio-catalog SNAPSHOT to ~/.m2"
    mvn -f "$FILEIO_CATALOG_HOME/pom.xml" -DskipTests -q install
    echo "==> packaging YCSB catalog-binding tarball"
    # dependency:copy-dependencies doesn't prune, so a stale jar would pollute
    # the assembly.  Wipe target/ for the binding before re-packaging.
    rm -rf "$YCSB_TREE/catalog/target"
    mvn -f "$YCSB_TREE/pom.xml" -pl :catalog-binding -am -DskipTests -q package
  fi

  local tarball
  tarball=$(ls -1 "$YCSB_TREE/catalog/target/ycsb-catalog-binding-"*.tar.gz 2>/dev/null | head -1)
  if [[ -z "$tarball" || ! -f "$tarball" ]]; then
    echo "❌ no catalog-binding tarball found at $YCSB_TREE/catalog/target/" >&2
    echo "   run 'bench.sh setup $cloud' (without --no-build) to produce it." >&2
    return 1
  fi
  local size; size=$(du -h "$tarball" | cut -f1)
  echo "==> shipping $(basename "$tarball") ($size) to VM"

  local user host
  user=$(cloud_ssh_user "$cloud")
  host=$(vm_host "$cloud")
  local ssh_opts=( -o StrictHostKeyChecking=accept-new -i "$AWS_SSH_PRIVATE_KEY" )

  scp "${ssh_opts[@]}" "$tarball"            "$user@$host:/tmp/ycsb.tgz"
  scp "${ssh_opts[@]}" "$YCSB_TREE/bin/lst.sh" "$user@$host:/tmp/lst.sh"

  echo "==> extracting on VM into /YCSB"
  ssh "${ssh_opts[@]}" "$user@$host" bash -s <<'REMOTE'
set -eux
rm -rf /YCSB
mkdir -p /YCSB
tar xzf /tmp/ycsb.tgz -C /tmp/
mv /tmp/ycsb-catalog-binding-*/. /YCSB/
mv /tmp/lst.sh /YCSB/bin/lst.sh
chmod +x /YCSB/bin/lst.sh /YCSB/bin/ycsb.sh
rm -rf /tmp/ycsb.tgz /tmp/ycsb-catalog-binding-*
REMOTE

  if [[ "$cloud" == "azure" ]]; then
    echo "==> copying SAS tokens to VM"
    rsync_to "$cloud" "${REPO_ROOT}/azure/tokens/" "/YCSB/tokens/"
  fi
  echo "==> setup complete"
}

cmd_run() {
  local cloud="$1"; shift
  local tier=std client=direct mode=cas
  local thread_range="$SWEEP_THREAD_RANGE" runs="$SWEEP_RUNS"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tier=*)    tier="${1#*=}" ;;
      --client=*)  client="${1#*=}" ;;
      --mode=*)    mode="${1#*=}" ;;
      --threads=*) thread_range="${1#*=}" ;;
      --runs=*)    runs="${1#*=}" ;;
      *) echo "❌ unknown opt: $1"; exit 1 ;;
    esac
    shift
  done
  local bucket; bucket=$(cloud_bucket_for_tier "$cloud" "$tier")
  echo "==> run $cloud tier=$tier client=$client mode=$mode bucket=$bucket"
  ssh_to "$cloud" \
    "cd /YCSB && CLOUD=$cloud TIER=$tier CLIENT=$client MODE=$mode \
      BUCKET='$bucket' THREAD_RANGE=$thread_range RUNS=$runs ./bin/lst.sh"
}

cmd_fetch() {
  local cloud="$1"; shift
  local dest="${1:-${RESULTS_ROOT}/$(date -u +%Y-%m-%dT%H%M%SZ)/$cloud}"
  mkdir -p "$dest"
  echo "==> fetching results to $dest"
  rsync_from "$cloud" "/YCSB/results/" "$dest/"
}

cmd_down() {
  local cloud="$1"
  terraform -chdir="$(benchmark_dir "$cloud")" destroy -auto-approve
}

cmd_status() {
  local cloud="$1"
  echo "==> infra ($cloud):"
  terraform -chdir="$(infra_dir "$cloud")" state list 2>/dev/null | head -20 || echo "  (no state)"
  echo "==> benchmark VM ($cloud):"
  if [[ -f "$(benchmark_dir "$cloud")/terraform.tfstate" ]]; then
    terraform -chdir="$(benchmark_dir "$cloud")" output 2>/dev/null || echo "  (no outputs)"
  else
    echo "  (not provisioned)"
  fi
}

# Returns 0 if the (cloud, tier, mode) combination is supported by the
# underlying FileIO implementation, 1 otherwise.  Skip combinations:
#   aws/std/append    — S3 standard has no append; Jan 2026 didn't measure it
#   gcp/std/append    — GCSFileIO.supportsAppend() == false (immutable objects)
#   gcp/rapid/append  — Rapid Storage appendable-object protocol is unsafe under
#                       contention (single-writer; silent byte loss on takeover);
#                       see iceberg/docs/docs/atomic_io_gcs_rapid.md
mode_supported() {
  local cloud="$1" tier="$2" mode="$3"
  case "$cloud,$tier,$mode" in
    aws,std,append)   return 1 ;;
    gcp,std,append)   return 1 ;;
    gcp,rapid,append) return 1 ;;
    *)                return 0 ;;
  esac
}

cmd_sweep() {
  local cloud="$1"
  cmd_up "$cloud"
  cmd_setup "$cloud"
  for tier in $(cloud_tiers "$cloud"); do
    for client in $SWEEP_CLIENTS; do
      for mode in $SWEEP_MODES; do
        if ! mode_supported "$cloud" "$tier" "$mode"; then
          echo "skip: $cloud/$tier/$mode (not supported by FileIO impl)"
          continue
        fi
        cmd_run "$cloud" --tier="$tier" --client="$client" --mode="$mode"
      done
    done
  done
  cmd_fetch "$cloud"
  cmd_down "$cloud"
}

# === Dispatch ===
[[ $# -ge 1 ]] || usage 1
CMD="$1"; shift
[[ $# -ge 1 ]] || { echo "❌ <cloud> required"; usage 1; }

for cloud_arg in "$@"; do
  if [[ "$cloud_arg" =~ ^(aws|azure|gcp)$ ]]; then
    case "$CMD" in
      init|setup|teardown) shift; "cmd_$CMD" "$cloud_arg" "$@"; break ;;
      up|fetch|down|status|sweep) "cmd_$CMD" "$cloud_arg" ;;
      run) shift; cmd_run "$cloud_arg" "$@"; break ;;
      *) echo "❌ unknown command: $CMD"; usage 1 ;;
    esac
  fi
done
