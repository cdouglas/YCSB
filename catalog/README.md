# Catalog Bindings

Test

# Build/run

1. From Iceberg branch: `./gradlew publishToMavenLocal` (installs `1.6.0-SNAPSHOT` to ~/.m2/repository)
2. Package: `mvn -pl site.ycsb:catalog-binding -am clean package`
3. load (init tables): `./bin/ycsb.sh load catalog -P workloads/lst -p gcp.creds=catalog/.secret/lst-consistency-8dd2dfbea73a.json`
4. run: `./bin/ycsb.sh run catalog -P workloads/lst -p gcp.creds=catalog/.secret/lst-consistency-8dd2dfbea73a.json`

# Debug

`ClassNotFoundException` for HTrace: run `mvn dependency:copy-dependencies` in `core` package