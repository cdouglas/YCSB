#!/usr/bin/env bash
set -euo pipefail

# Optional: enable remote debugging
# export JAVA_OPTS="-agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=*:5005"

# === Determine cloud environment and thread range ===
CLOUD="${CLOUD:-${1:-}}"
THREAD_RANGE="${2:-1..16}"
SKIP_UPLOAD=false

# If args were passed explicitly, skip upload
if [[ -n "${1-}" || -n "${2-}" ]]; then
  SKIP_UPLOAD=true
fi

# Auto-detect cloud environment if not set
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

RESULTDIR=results
AZURE_BUCKET=lst-consistency
GCP_BUCKET=lst-consistency
S3_BUCKET=casalog

OUTDIR=$RESULTDIR/$CLOUD
mkdir -p "$OUTDIR"

for THREADS in $(eval echo {$THREAD_RANGE}); do
  TESTNAME=${CLOUD}_${THREADS}
  echo "🚀 Running YCSB benchmark on ${CLOUD} with ${THREADS} threads..."
  ./bin/ycsb.sh run catalog-fileio -P workloads/lst \
    -p fileio.store=${CLOUD} \
    -p measurementtype=hdrhistogram+raw \
    -p exportfile="${OUTDIR}/${TESTNAME}" \
    -threads ${THREADS} | tee ${OUTDIR}/${TESTNAME}_raw
  sleep 2
done

TARBALL="${CLOUD}_results_$(date +%s).tgz"
BUCKET_PATH="benchmark-results/${TARBALL}"

echo "📦 Compressing all results into $TARBALL..."
tar czf "$TARBALL" -C "$RESULTDIR" .

if [ "$SKIP_UPLOAD" = true ]; then
  echo "🚫 Upload skipped due to manual arguments."
  exit 0
fi

# === Upload logic ===
upload_to_azure() {
  echo "☁️ Uploading to Azure Blob Storage..."
  azcopy login --identity
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

echo "🚚 Uploading final results archive..."
case $CLOUD in
  azure) upload_to_azure ;;
  aws)   upload_to_aws ;;
  gcp)   upload_to_gcp ;;
  *)     echo "❌ Unknown cloud environment: $CLOUD"; exit 1 ;;
esac

echo "✅ All benchmarks complete and uploaded!"
