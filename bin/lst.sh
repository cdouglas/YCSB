#!/usr/bin/env bash
set -euo pipefail

RESULTDIR=results
AZURE_BUCKET=lst-consistency
GCP_BUCKET=lst-consistency
S3_BUCKET=casalog

# redirect output
mkdir -p ${RESULTDIR}
MYOUTFILE=out-$(date +"%Y-%m-%d_%H-%M-%S").log
MYOUTPUT=${RESULTDIR}/$MYOUTFILE


# Optional: enable remote debugging
# export JAVA_OPTS="-agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=*:5005"

# === Determine cloud environment and thread range ===
LOCAL_RUN=false

if [[ "${1:-}" == "--local" ]]; then
  LOCAL_RUN=true
  RUNS=1
  shift
  # redirect to stdout, log file
  exec > >(tee ${MYOUTPUT}) 2>&1
else
  # redirct output to log file
  exec > ${MYOUTPUT} 2>&1
fi
# CLOUD ∈ { azure, aws, gcp }
CLOUD="${CLOUD:-${1:-}}"
# x..y
THREAD_RANGE="${THREAD_RANGE:-${2:-1..16}}"
# iterations per thread
RUNS="${RUNS:-${3:-5}}"
# which YCSB client to use
CLIENT="${CLIENT:-${4:-direct}}"
# how many concurrent clients to fork
JVM_PER_THREAD="${JVM_PER_THREAD:-${5:-true}}"
# foreach update proportion
UPD_PROP="${UPD_PROP:-1.0}"
SAS_DIR="${SAS_DIR:-tokens}"
SAS_EXPR="${SAS_EXPR:-client%d_20250527.json}"
#SAS_KEYS="${SAS_KEYS:-""}"

echo "CFG CLOUD:${CLOUD} THREAD_RANGE:${THREAD_RANGE} RUNS:${RUNS} CLIENT:${CLIENT} JVM:${JVM_PER_THREAD} UPD_PROP:$UPD_PROP"

# Auto-detect cloud environment if not set
if [[ "$LOCAL_RUN" != true ]]; then
if [[ -z "$CLOUD" ]]; then
  if curl -s -H Metadata:true "http://169.254.169.254/metadata/instance?api-version=2021-02-01" | grep -q "compute"; then
    echo "☁️ Detected Azure"
    CLOUD="azure"
  elif curl -s "http://169.254.169.254/latest/meta-data/" | grep -q "instance-id"; then
    echo "☁️ Detected AWS"
    CLOUD="aws"
  elif curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/" | grep -q "instance"; then
    echo "☁️ Detected GCP"
    CLOUD="gcp"
  else
    echo "❌ Could not detect or infer cloud environment. Please set CLOUD or pass it as the first argument."
    exit 1
  fi
fi

fi


if [[ "$LOCAL_RUN" != true ]]; then
  # === Export cloud instance metadata if applicable ===
  if [[ "$CLOUD" == "azure" ]]; then
    echo "📋 Saving Azure instance metadata to nodeinfo.json..."
    curl -s -H "Metadata: true" \
      "http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01" \
      -o "nodeinfo.json"
    VM=$(jq -r '.vmSize' nodeinfo.json | tr '_' '-')

  elif [[ "$CLOUD" == "aws" ]]; then
    echo "📋 Saving AWS instance metadata to nodeinfo.json..."
    curl -s "http://169.254.169.254/latest/dynamic/instance-identity/document" \
      -o "nodeinfo.json"
    VM=$(jq -r '.instanceType' nodeinfo.json | tr '.' '-')

  elif [[ "$CLOUD" == "gcp" ]]; then
    echo "📋 Saving GCP instance metadata to nodeinfo.json..."
    curl -s -H "Metadata-Flavor: Google" \
      "http://metadata.google.internal/computeMetadata/v1/instance/?recursive=true" \
      -o "nodeinfo.json"
    VM=$(basename $(jq -r '.machineType' nodeinfo.json))

  fi

  OUTDIR=${RESULTDIR}/${CLOUD}_${VM}

else

  OUTDIR=${RESULTDIR}/${CLOUD}

fi

mkdir -p "$OUTDIR"

if [ -f srcinfo.json ]; then
  mv srcinfo.json "$OUTDIR"
fi

if [ -f nodeinfo.json ]; then
  mv nodeinfo.json $OUTDIR
fi

# -p updateproportion=$UPDATE
# -p readproportion=$(echo "scale=2; 1.0 - $UPDATE" | bc)

if [[ "$JVM_PER_THREAD" == "true" ]]; then
  # JVM per thread
  echo "Running JVM per thread... $RUNS"
  for THREADS in $(eval echo {$THREAD_RANGE}); do
    echo "DEBUG $THREADS / $THREAD_RANGE"
    for ((i = 1; i <= RUNS; i++)); do
      # triggers pipefail for some damn reason
      PREFIX=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c8) || true
      PIDS=()
      for u in $UPD_PROP; do
        for ((c = 1; c <= THREADS; c++)); do
          if [ -d $SAS_DIR ]; then
            KEY_PATH=$(printf "${SAS_DIR}/${SAS_EXPR}" $c)
          else
            KEY_PATH="NONE"
          fi
          TESTNAME="${CLOUD}_${THREADS}_run${i}_${c}_${u}"
          echo "🚀 Running YCSB benchmark on ${CLOUD} with ${c}/${THREADS} JVMs (run ${i}/${RUNS})..."
          (
          ./bin/ycsb.sh run catalog-${CLIENT} -P workloads/lst \
            -p fileio.store=${CLOUD} \
            -p measurementtype=hdrhistogram+raw \
            -p exportfile="${OUTDIR}/${TESTNAME}" \
            -p updateproportion=${u} \
            -p readproportion=$(echo "scale=2; 1.0 - $u" | bc) \
            -p fileio.key.path=${KEY_PATH} \
            -p fileio.test.run=${PREFIX} \
            -threads 1 | tee ${OUTDIR}/${TESTNAME}_raw
          ) &
          PIDS+=($!)
        done
        # wait for concurrent clients to finish
        for pid in "${PIDS[@]}"; do
          wait "$pid"
        done
        sleep 2
      done
    done
  done
else
  # all threads in the same JVM
  for THREADS in $(eval echo {$THREAD_RANGE}); do
    for ((i = 1; i <= RUNS; i++)); do
      TESTNAME="${CLOUD}_${THREADS}_run${i}_1"
      echo "🚀 Running YCSB benchmark on ${CLOUD} with ${THREADS} threads (run ${i}/${RUNS})..."
      ./bin/ycsb.sh run catalog-${CLIENT} -P workloads/lst \
        -p fileio.store=${CLOUD} \
        -p measurementtype=hdrhistogram+raw \
        -p exportfile="${OUTDIR}/${TESTNAME}" \
        -threads ${THREADS} | tee ${OUTDIR}/${TESTNAME}_raw
      sleep 2
    done
  done
fi

TARBALL="${CLOUD}_results_$(date +%s).tgz"
BUCKET_PATH="ycsb-results/${TARBALL}"

# checkpoint our output
gzip -c $MYOUTPUT > $OUTDIR/$MYOUTFILE.gz

echo "📦 Compressing all results into $TARBALL..."
tar czf "$TARBALL" -C "$RESULTDIR" .

cp $TARBALL $RESULTDIR

if [ "$LOCAL_RUN" = true ]; then
  echo "🚫 Upload skipped: local run"
  exit 0
fi

# === Upload logic ===
upload_to_azure() {
  echo "☁️ Uploading to Azure Blob Storage..."
  azcopy copy "$TARBALL" "https://${AZURE_BUCKET}.blob.core.windows.net/${BUCKET_PATH}"
}

upload_to_aws() {
  echo "☁️ Uploading to S3..."
  aws s3 cp "$TARBALL" "s3://${S3_BUCKET}/${BUCKET_PATH}"
}

upload_to_gcp() {
  echo "☁️ Uploading to GCS..."
  gsutil cp "$TARBALL" "gs://${GCP_BUCKET}/${BUCKET_PATH}"
}

if [[ "$LOCAL_RUN" == true ]]; then
  echo "🚫 Local run: skipping upload."
  exit 0
fi

echo "🚚 Uploading final results archive..."
case $CLOUD in
  azure) upload_to_azure ;;
  aws)   upload_to_aws ;;
  gcp)   upload_to_gcp ;;
  *)     echo "❌ Unknown cloud environment: $CLOUD"; exit 1 ;;
esac

echo "✅ All benchmarks complete and uploaded!"
