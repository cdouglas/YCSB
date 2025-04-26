#!/usr/bin/env bash
set -euo pipefail


ICEBERG_HOME=${1:-/home/chris/work/iceberg}
YCSB_HOME=${2:-/home/chris/src/YCSB}
DOCKER_IMG=${3:-cdouglas/catalog-bench}
DOCKER_TAG=${4:-latest}
CLIENT=${5:-catalog-fileio}

# install iceberg to maven local
build_iceberg() {
  pushd ${ICEBERG_HOME}
  ./gradlew publishToMavenLocal
  popd
}

# YCSB
build_ycsb() {
  pushd ${YCSB_HOME}
  pushd catalog
  mvn clean
  popd
  # ignore exit code
  mvn -Psource-run -pl site.ycsb:$(echo $CLIENT | cut -d'-' -f 1)-binding -am package -DskipTests || true
}

write_src_info() {
  echo "{ \"ycsb\": \"$(cd $YCSB_HOME ; git rev-parse HEAD)\", \"iceberg\":\"$(cd $ICEBERG_HOME ; git rev-parse HEAD)\" }" \
    | jq \
    | tee srcinfo.json
}

build_docker() {
  docker build -t ${DOCKER_IMG}:${DOCKER_TAG} .
}

push_docker() {
  docker push ${DOCKER_IMG}:${DOCKER_TAG}
}

# MAIN

build_iceberg
build_ycsb
write_src_info
build_docker
push_docker
