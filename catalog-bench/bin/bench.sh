#!/usr/bin/env bash
set -euo pipefail

# bench.sh — single driver for the YCSB conditional-write benchmark refresh.
#
# Usage:
#   bench.sh init     <cloud> [--apply]    apply infra terraform once (idempotent; runs imports)
#   bench.sh up       <cloud>              apply benchmark VM terraform
#   bench.sh setup    <cloud> [--no-build]  build SNAPSHOTs + binding locally, rsync to VM
#   bench.sh run      <cloud> [opts]       run one cell via lst.sh on the VM (detached, blocks until done)
#   bench.sh wait     <cloud>              block until the in-flight cell on the VM finishes
#   bench.sh tail     <cloud>              follow the live log of the in-flight cell
#   bench.sh fetch    <cloud> [<dest>]     rsync /mnt/results/ from VM into ${RESULTS_ROOT}/<date>/
#   bench.sh down     <cloud>              terraform destroy the VM (infra survives)
#   bench.sh teardown <cloud> [--yes]      terraform destroy the infra (buckets, IAM, SAS) — DESTROYS DATA
#   bench.sh status   <cloud>              show infra + VM + in-flight benchmark state
#   bench.sh sweep    <cloud>              up + setup + run (matrix from bench.env) + fetch + down
#
# Disconnect / reconnect:
#   'run' launches lst.sh on the VM via nohup (detached from the SSH session)
#   and then blocks the workstation by polling.  If the workstation
#   disconnects, the on-VM benchmark keeps going.  Reconnect with
#   'bench.sh status <cloud>' (live tail) or 'bench.sh wait <cloud>'
#   (resume blocking).  'bench.sh tail <cloud>' streams the log.
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
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i "$AWS_SSH_PRIVATE_KEY" "$user@$host" "$@"
}

rsync_to() {
  local cloud="$1" src="$2" dest="$3"
  local user host
  user=$(cloud_ssh_user "$cloud")
  host=$(vm_host "$cloud")
  rsync -az --delete \
    -e "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i $AWS_SSH_PRIVATE_KEY" \
    "$src" "$user@$host:$dest"
}

rsync_from() {
  local cloud="$1" src="$2" dest="$3"
  local user host
  user=$(cloud_ssh_user "$cloud")
  host=$(vm_host "$cloud")
  rsync -az \
    -e "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i $AWS_SSH_PRIVATE_KEY" \
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

  # State-hygiene migrations and imports.  Each runs only if needed.  Failures
  # here are fatal — silently swallowing them lets `apply` later try to create
  # already-existing resources (e.g. BucketAlreadyOwnedByYou on S3 Express).
  case "$cloud" in
    aws)
      if ! terraform -chdir="$dir" state list 2>/dev/null | grep -q '^aws_s3_directory_bucket\.express$'; then
        echo "==> importing existing S3 Express bucket"
        if ! terraform -chdir="$dir" import aws_s3_directory_bucket.express "${AWS_BUCKET_X}"; then
          echo "❌ failed to import S3 Express bucket.  Common cause: the AWS principal lacks" >&2
          echo "   iam:GetRole/GetRolePolicy/ListRolePolicies/ListAttachedRolePolicies and" >&2
          echo "   s3express:ListTagsForResource/GetBucketTagging on the relevant ARNs." >&2
          return 1
        fi
      fi
      ;;
    azure)
      # Migrate legacy single-container layout: pre-2026-05 main.tf had a single
      # `azurerm_storage_container.container` (Premium-only).  The split into
      # container_premium + container_standard requires a state mv so the next
      # plan doesn't propose destroying the existing data container.
      if terraform -chdir="$dir" state list 2>/dev/null | grep -q '^azurerm_storage_container\.container$'; then
        echo "==> migrating legacy state: container → container_premium"
        terraform -chdir="$dir" state mv \
          azurerm_storage_container.container azurerm_storage_container.container_premium
      fi
      if ! terraform -chdir="$dir" state list 2>/dev/null | grep -q '^azurerm_storage_account\.adls_standard$'; then
        echo "❌ adls_standard not in state.  Run this with your subscription + RG, then re-run bench.sh init azure:" >&2
        echo "    terraform -chdir=$dir import azurerm_storage_account.adls_standard \\" >&2
        echo "        '/subscriptions/<SUB>/resourceGroups/<RG>/providers/Microsoft.Storage/storageAccounts/lstnsgym'" >&2
        return 1
      fi
      ;;
    gcp)
      if ! terraform -chdir="$dir" state list 2>/dev/null | grep -q '^google_storage_bucket\.rapid$'; then
        echo "==> importing existing Rapid bucket"
        if ! terraform -chdir="$dir" import google_storage_bucket.rapid "${GCP_BUCKET_RAPID}"; then
          echo "❌ failed to import Rapid bucket ${GCP_BUCKET_RAPID}." >&2
          return 1
        fi
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
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 \
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
  local ssh_opts=( -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i "$AWS_SSH_PRIVATE_KEY" )

  scp "${ssh_opts[@]}" "$tarball"            "$user@$host:/tmp/ycsb.tgz"
  scp "${ssh_opts[@]}" "$YCSB_TREE/bin/lst.sh" "$user@$host:/tmp/lst.sh"

  echo "==> extracting on VM into /YCSB"
  ssh "${ssh_opts[@]}" "$user@$host" bash -s <<'REMOTE'
set -eux
# Clear contents (we can't rm -rf /YCSB itself; / is root-owned).  /YCSB
# itself is created and chowned by the VM's startup script.
mkdir -p /YCSB
find /YCSB -mindepth 1 -delete
tar xzf /tmp/ycsb.tgz -C /YCSB --strip-components=1
mv /tmp/lst.sh /YCSB/bin/lst.sh
chmod +x /YCSB/bin/lst.sh /YCSB/bin/ycsb.sh
rm -f /tmp/ycsb.tgz
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
  local block=true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tier=*)    tier="${1#*=}" ;;
      --client=*)  client="${1#*=}" ;;
      --mode=*)    mode="${1#*=}" ;;
      --threads=*) thread_range="${1#*=}" ;;
      --runs=*)    runs="${1#*=}" ;;
      --no-wait)   block=false ;;
      *) echo "❌ unknown opt: $1"; exit 1 ;;
    esac
    shift
  done
  local bucket; bucket=$(cloud_bucket_for_tier "$cloud" "$tier")

  # Refuse to overwrite an in-flight run on the same VM.
  local existing_pid
  existing_pid=$(ssh_to "$cloud" "cat /YCSB/results/.bench.pid 2>/dev/null" || true)
  existing_pid=$(echo "$existing_pid" | tr -d '[:space:]')
  if [[ -n "$existing_pid" ]] && ssh_to "$cloud" "kill -0 $existing_pid 2>/dev/null"; then
    echo "❌ benchmark already running on $cloud (PID $existing_pid)" >&2
    echo "   bench.sh wait $cloud   to block until it finishes" >&2
    echo "   bench.sh tail $cloud   to follow its log" >&2
    return 1
  fi

  local cell="${cloud}_${tier}_${client}_${mode}"
  echo "==> launching cell $cell on $cloud (bucket=$bucket, threads=$thread_range, runs=$runs)"

  # nohup + detach so the workstation can disconnect without killing lst.sh.
  ssh_to "$cloud" "
    set -e
    cd /YCSB
    mkdir -p results
    rm -f results/.bench.pid results/.bench.cell results/.bench.log
    echo '$cell' > results/.bench.cell
    nohup env CLOUD='$cloud' TIER='$tier' CLIENT='$client' MODE='$mode' \\
      BUCKET='$bucket' THREAD_RANGE='$thread_range' RUNS='$runs' \\
      ./bin/lst.sh </dev/null >results/.bench.log 2>&1 &
    echo \$! > results/.bench.pid
  "
  local pid
  pid=$(ssh_to "$cloud" "cat /YCSB/results/.bench.pid" | tr -d '[:space:]')
  echo "==> launched detached on VM (PID $pid)"

  if [[ "$block" == "true" ]]; then
    cmd_wait "$cloud"
  else
    echo "    bench.sh wait $cloud   to block until done"
    echo "    bench.sh tail $cloud   to follow the log"
  fi
}

cmd_wait() {
  local cloud="$1"
  local pid cell
  pid=$(ssh_to "$cloud" "cat /YCSB/results/.bench.pid 2>/dev/null" | tr -d '[:space:]' || true)
  cell=$(ssh_to "$cloud" "cat /YCSB/results/.bench.cell 2>/dev/null" | tr -d '[:space:]' || true)
  if [[ -z "$pid" ]]; then
    echo "no benchmark recorded on $cloud"
    return 0
  fi
  if ! ssh_to "$cloud" "kill -0 $pid 2>/dev/null"; then
    echo "PID $pid is not running (cell $cell already finished)"
    return 0
  fi
  echo "==> waiting for cell $cell on $cloud (PID $pid; polling every 30s)"
  # Distinguish "PID gone" (cell finished) from "ssh unreachable" (transient).
  # Without this guard, the loop would exit on any SSH failure and falsely
  # report the cell complete — observed in May 2026 GCP run where the VM
  # became unreachable mid-cell after ~75 min.
  local ssh_fail=0
  while true; do
    if ! ssh_to "$cloud" "true" >/dev/null 2>&1; then
      ssh_fail=$((ssh_fail + 1))
      if (( ssh_fail >= 10 )); then
        echo "❌ ssh to $cloud VM unreachable for >5 min; giving up on cell $cell" >&2
        return 1
      fi
      echo "==> ssh transient failure (count=$ssh_fail); retrying in 30s" >&2
      sleep 30
      continue
    fi
    ssh_fail=0
    if ! ssh_to "$cloud" "kill -0 $pid 2>/dev/null"; then
      echo "==> cell $cell complete"
      return 0
    fi
    sleep 30
  done
}

cmd_tail() {
  local cloud="$1"
  local user host
  user=$(cloud_ssh_user "$cloud")
  host=$(vm_host "$cloud")
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i "$AWS_SSH_PRIVATE_KEY" \
    "$user@$host" "tail -f /YCSB/results/.bench.log"
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
  local vm_up=false
  if [[ -f "$(benchmark_dir "$cloud")/terraform.tfstate" ]]; then
    if terraform -chdir="$(benchmark_dir "$cloud")" output 2>/dev/null; then
      vm_up=true
    else
      echo "  (state exists but no outputs)"
    fi
  else
    echo "  (not provisioned)"
  fi
  if [[ "$vm_up" == "true" ]]; then
    echo "==> benchmark process on VM:"
    local pid cell
    pid=$(ssh_to "$cloud" "cat /YCSB/results/.bench.pid 2>/dev/null" | tr -d '[:space:]' || true)
    cell=$(ssh_to "$cloud" "cat /YCSB/results/.bench.cell 2>/dev/null" | tr -d '[:space:]' || true)
    if [[ -n "$pid" ]] && ssh_to "$cloud" "kill -0 $pid 2>/dev/null"; then
      echo "  RUNNING: cell=$cell PID=$pid"
      echo "  log tail:"
      ssh_to "$cloud" "tail -10 /YCSB/results/.bench.log 2>/dev/null | sed 's/^/    /'" || true
    elif [[ -n "$pid" ]]; then
      echo "  finished: last cell=$cell PID=$pid (no longer running)"
    else
      echo "  no benchmark recorded"
    fi
  fi
}

# Returns 0 if the (cloud, tier, mode) combination is supported by the
# underlying FileIO implementation, 1 otherwise.  Skip combinations:
#   aws/std/append    — S3 standard has no append primitive (only full-object PUT)
#   gcp/std/append    — GCSFileIO.supportsAppend() == false (immutable objects)
#   gcp/rapid/append  — Rapid appendable-object protocol unsafe under contention
#                       (single-writer; silent byte loss on takeover);
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
      up|fetch|down|status|sweep|wait|tail) "cmd_$CMD" "$cloud_arg" ;;
      run) shift; cmd_run "$cloud_arg" "$@"; break ;;
      *) echo "❌ unknown command: $CMD"; usage 1 ;;
    esac
  fi
done
