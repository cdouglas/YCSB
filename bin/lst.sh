#!/usr/bin/env bash

# export JAVA_OPTS="-agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=*:5005"

STORE=${1:-azure}
THREADS=${2:-8}
RESULTDIR=results

OUTDIR=$RESULTDIR/$STORE
TESTNAME=${STORE}_${THREADS}

mkdir -p "$OUTDIR"
./bin/ycsb.sh run catalog-fileio -P workloads/lst -p fileio.store=${STORE} -p measurementtype=hdrhistogram+raw -p exportfile="${OUTDIR}/${TESTNAME}" -threads ${THREADS} | tee ${OUTDIR}/${TESTNAME}_raw
