#!/usr/bin/env bash

# export JAVA_OPTS="-agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=*:5005"

STORE=${1:-azure}
THREADS=${2:-8}
RESULTDIR=results

AZURE_BUCKET=lst_consistency
GCP_BUCKET=lst_consistency
S3_BUCKET=casalog

OUTDIR=$RESULTDIR/$STORE
TESTNAME=${STORE}_${THREADS}
TARBALL="${TESTNAME}.tgz"
BUCKET_PATH="benchmark-results/results-$(date +%s).tar.gz"

mkdir -p "$OUTDIR"

echo "🔧 Running YCSB benchmark..."
./bin/ycsb.sh run catalog-fileio -P workloads/lst -p fileio.store=${STORE} -p measurementtype=hdrhistogram+raw -p exportfile="${OUTDIR}/${TESTNAME}" -threads ${THREADS} | tee ${OUTDIR}/${TESTNAME}_raw

echo "📦 Compressing results..."
tar czf $TARBALL -C $RESULTDIR


echo "🌐 Detecting cloud environment..."

upload_to_azure() {
  echo "🔄 Uploading to Azure Blob Storage..."
  azcopy login --identity
  azcopy copy "${TARBALL}" "https://${AZURE_BUCKET}.blob.core.windows.net/${BUCKET_PATH}"
}

upload_to_aws() {
  echo "🔄 Uploading to S3..."
  aws s3 cp "${TARBALL}" "s3://your-bucket/${BUCKET_PATH}"
}

upload_to_gcp() {
  echo "🔄 Uploading to GCS..."
  gsutil cp "${TARBALL}" "gs://your-bucket/${BUCKET_PATH}"
}

# Try each cloud's metadata endpoint
if curl -s -H Metadata:true "http://169.254.169.254/metadata/instance?api-version=2021-02-01" | grep -q "compute"; then
  echo "☁️ Detected Azure"
  upload_to_azure
elif curl -s "http://169.254.169.254/latest/meta-data/" | grep -q "instance-id"; then
  echo "☁️ Detected AWS"
  upload_to_aws
elif curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/" | grep -q "instance"; then
  echo "☁️ Detected GCP"
  upload_to_gcp
else
  echo "❌ Cloud environment not detected. Skipping upload."
  exit 1
fi

echo "✅ Benchmark complete and uploaded!"

