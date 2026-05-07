#!/usr/bin/env bash
set -euo pipefail

# Run a single (CLOUD, TIER, CLIENT, MODE, AUTH) sweep cell on the local VM.
#
# Driven by env vars (defaults reflect Jan 2026 methodology):
#   CLOUD         aws | azure | gcp                          (required: cloud provider for FileIO dispatch)
#   TIER          std | x | rapid                            (default: std)
#   CLIENT        direct | fileio                            (default: direct; raw FileIO vs full FileIOCatalog)
#   MODE          cas | append                               (default: cas)
#   AUTH          metal | sas                                (default: metal on AWS/GCP, sas on Azure)
#   BUCKET        bucket name to pass via -p fileio.bucket   (required; bench.sh sets per TIER)
#   THREAD_RANGE  shell brace expansion, e.g., 1..16         (default: 1..16)
#   RUNS          trials per thread count                    (default: 5)
#   JVM_PER_THREAD  true | false                             (default: true; one JVM per concurrent client)
#   UPD_PROP      update proportion(s)                       (default: 1.0)
#   SAS_DIR       dir holding SAS JSON files (Azure only)    (default: tokens)
#   SAS_EXPR      printf template for SAS file per JVM       (default: client%d_20250527.json)
#
# Output: ${RESULTDIR}/${OUTDIR_BASE} where OUTDIR_BASE follows the 5-token
# analysis convention: ${CLOUD_TAG}_${VM}_${CLIENT_TAG}_${MODE_TAG}_${AUTH}.
# After all runs in this cell, tars to ${RESULTDIR}/${OUTDIR_BASE}.tgz.
#
# bench.sh fetches the tarball back via rsync; this script does NOT upload to
# any cloud bucket.

RESULTDIR=${RESULTDIR:-results}

mkdir -p ${RESULTDIR}
MYOUTFILE=out-$(date +"%Y-%m-%d_%H-%M-%S").log
MYOUTPUT=${RESULTDIR}/$MYOUTFILE

LOCAL_RUN=false
if [[ "${1:-}" == "--local" ]]; then
  LOCAL_RUN=true
  RUNS=${RUNS:-1}
  shift
  exec > >(tee ${MYOUTPUT}) 2>&1
else
  exec > ${MYOUTPUT} 2>&1
fi

# === Required + defaults ===
CLOUD="${CLOUD:-${1:-}}"
THREAD_RANGE="${THREAD_RANGE:-${2:-1..16}}"
RUNS="${RUNS:-${3:-5}}"
CLIENT="${CLIENT:-${4:-direct}}"
JVM_PER_THREAD="${JVM_PER_THREAD:-${5:-true}}"
TIER="${TIER:-std}"
MODE="${MODE:-cas}"
UPD_PROP="${UPD_PROP:-1.0}"
SAS_DIR="${SAS_DIR:-tokens}"
SAS_EXPR="${SAS_EXPR:-client%d_20250527.json}"

if [[ "$LOCAL_RUN" != true && -z "$CLOUD" ]]; then
  if curl -s -H Metadata:true "http://169.254.169.254/metadata/instance?api-version=2021-02-01" | grep -q "compute"; then
    CLOUD="azure"
  elif curl -s "http://169.254.169.254/latest/meta-data/" | grep -q "instance-id"; then
    CLOUD="aws"
  elif curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/" | grep -q "instance"; then
    CLOUD="gcp"
  else
    echo "❌ Could not detect cloud. Set CLOUD or pass it as the first argument."
    exit 1
  fi
fi

# AUTH default: metal on AWS/GCP, sas on Azure.
if [[ -z "${AUTH:-}" ]]; then
  if [[ "$CLOUD" == "azure" ]]; then AUTH=sas; else AUTH=metal; fi
fi

# BUCKET is required: per-TIER bucket name lives in bench.env, passed in by bench.sh.
if [[ -z "${BUCKET:-}" ]]; then
  echo "❌ BUCKET env var is required (per-TIER bucket name; bench.sh normally sets this)."
  exit 1
fi

# === Tag derivation for the 5-token OUTDIR convention ===
case "$CLOUD,$TIER" in
  aws,std)         CLOUD_TAG=aws;       FILEIO_STORE=aws ;;
  aws,x)           CLOUD_TAG=awsx;      FILEIO_STORE=aws ;;
  azure,std)       CLOUD_TAG=azure;     FILEIO_STORE=azure ;;
  azure,x)         CLOUD_TAG=azurex;    FILEIO_STORE=azure ;;
  gcp,std)         CLOUD_TAG=gcp;       FILEIO_STORE=gcp ;;
  gcp,rapid)       CLOUD_TAG=gcprapid;  FILEIO_STORE=gcprapid ;;
  *) echo "❌ Unsupported CLOUD/TIER combination: $CLOUD/$TIER"; exit 1 ;;
esac

case "$CLIENT" in
  direct) CLIENT_TAG=direct ;;
  fileio) CLIENT_TAG=catalog ;;
  *) echo "❌ Unknown CLIENT (must be direct|fileio): $CLIENT"; exit 1 ;;
esac

case "$MODE" in
  cas)    MODE_TAG=CAS;    MAX_LOG_SIZE_OVERRIDE=0 ;;
  append) MODE_TAG=append; MAX_LOG_SIZE_OVERRIDE="" ;;  # use workload default
  *) echo "❌ Unknown MODE (must be cas|append): $MODE"; exit 1 ;;
esac

# Reject unsafe combinations (Rapid Storage cannot serve concurrent APPEND)
if [[ "$CLOUD_TAG" == "gcprapid" && "$MODE" == "append" ]]; then
  echo "❌ APPEND is unsafe on GCS Rapid Storage (single-writer protocol; silent byte loss on takeover)."
  exit 1
fi

echo "CFG CLOUD:${CLOUD} TIER:${TIER} CLIENT:${CLIENT} MODE:${MODE} AUTH:${AUTH} \
THREAD_RANGE:${THREAD_RANGE} RUNS:${RUNS} JVM:${JVM_PER_THREAD} BUCKET:${BUCKET}"

# === Capture instance metadata ===
if [[ "$LOCAL_RUN" != true ]]; then
  if [[ "$CLOUD" == "azure" ]]; then
    curl -s -H "Metadata: true" \
      "http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01" \
      -o "nodeinfo.json"
    VM=$(jq -r '.vmSize' nodeinfo.json | tr '_' '-')
  elif [[ "$CLOUD" == "aws" ]]; then
    curl -s "http://169.254.169.254/latest/dynamic/instance-identity/document" \
      -o "nodeinfo.json"
    VM=$(jq -r '.instanceType' nodeinfo.json | tr '.' '-')
  elif [[ "$CLOUD" == "gcp" ]]; then
    curl -s -H "Metadata-Flavor: Google" \
      "http://metadata.google.internal/computeMetadata/v1/instance/?recursive=true" \
      -o "nodeinfo.json"
    VM=$(basename $(jq -r '.machineType' nodeinfo.json))
  fi
else
  VM="${VM:-local}"
fi

OUTDIR_BASE="${CLOUD_TAG}_${VM}_${CLIENT_TAG}_${MODE_TAG}_${AUTH}"
OUTDIR="${RESULTDIR}/${OUTDIR_BASE}"
mkdir -p "$OUTDIR"

[[ -f srcinfo.json ]] && mv srcinfo.json "$OUTDIR" || true
[[ -f nodeinfo.json ]] && mv nodeinfo.json "$OUTDIR" || true

# === Build the YCSB invocation arg list ===
YCSB_ARGS=(
  -P workloads/lst
  -p fileio.store=${FILEIO_STORE}
  -p fileio.bucket=${BUCKET}
  -p measurementtype=hdrhistogram+raw
)
if [[ -n "$MAX_LOG_SIZE_OVERRIDE" ]]; then
  YCSB_ARGS+=( -p fileio.max.log.size=${MAX_LOG_SIZE_OVERRIDE} )
fi

# === Run loop ===
if [[ "$JVM_PER_THREAD" == "true" ]]; then
  echo "JVM-per-thread: $RUNS runs per thread count"
  for THREADS in $(eval echo {$THREAD_RANGE}); do
    for ((i = 1; i <= RUNS; i++)); do
      PREFIX=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c8) || true
      PIDS=()
      for u in $UPD_PROP; do
        for ((c = 1; c <= THREADS; c++)); do
          if [[ "$AUTH" == "sas" && -d "$SAS_DIR" ]]; then
            KEY_PATH=$(printf "${SAS_DIR}/${SAS_EXPR}" $c)
          else
            KEY_PATH="NONE"
          fi
          TESTNAME="${CLOUD_TAG}_${THREADS}_run${i}_${c}_${u}"
          echo "🚀 ${CLOUD_TAG} t=${THREADS} jvm=${c} run=${i}/${RUNS} mode=${MODE}"
          (
          ./bin/ycsb.sh run catalog-${CLIENT} \
            "${YCSB_ARGS[@]}" \
            -p exportfile="${OUTDIR}/${TESTNAME}" \
            -p updateproportion=${u} \
            -p readproportion=$(echo "scale=2; 1.0 - $u" | bc) \
            -p fileio.key.path=${KEY_PATH} \
            -p fileio.test.run=${PREFIX} \
            -threads 1 | tee ${OUTDIR}/${TESTNAME}_raw
          ) &
          PIDS+=($!)
        done
        for pid in "${PIDS[@]}"; do wait "$pid"; done
        sleep 2
      done
    done
  done
else
  echo "Single-JVM-per-run: $RUNS runs per thread count"
  for THREADS in $(eval echo {$THREAD_RANGE}); do
    for ((i = 1; i <= RUNS; i++)); do
      TESTNAME="${CLOUD_TAG}_${THREADS}_run${i}_1"
      echo "🚀 ${CLOUD_TAG} t=${THREADS} run=${i}/${RUNS} mode=${MODE}"
      ./bin/ycsb.sh run catalog-${CLIENT} \
        "${YCSB_ARGS[@]}" \
        -p exportfile="${OUTDIR}/${TESTNAME}" \
        -threads ${THREADS} | tee ${OUTDIR}/${TESTNAME}_raw
      sleep 2
    done
  done
fi

# === Tar the cell output; bench.sh fetches via rsync ===
gzip -c $MYOUTPUT > "${OUTDIR}/${MYOUTFILE}.gz"
TARBALL="${RESULTDIR}/${OUTDIR_BASE}.tgz"
tar czf "$TARBALL" -C "$RESULTDIR" "$OUTDIR_BASE"
echo "✅ Cell complete: ${TARBALL}"
