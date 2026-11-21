#!/bin/sh
set -eu

image=${1:?usage: test.sh IMAGE [FLAVOR]}
flavor=${2:-plain}
recipe="$(dirname "$0")/../melange.yaml"
expected_version=$(sed -n 's/^  version: "\([^"]*\)".*$/\1/p' "$recipe")
[ -n "$expected_version" ] || { printf 'package version not found\n' >&2; exit 1; }
work=$(mktemp -d)
label="verity-test=spark-$$"
start=$(date +%s)

cleanup() {
  docker ps -aq --filter "label=$label" | xargs -r docker rm -f >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

# Every container gets a deadline, so a stall fails at the step that stalled.
# CI also runs this test for arm64 under emulation: bind Spark to loopback, and
# stop the JIT at C1 so emulated C2 compilation does not dominate the run.
run() {
  timeout "${SMOKE_STEP_TIMEOUT:-900}" docker run --rm --label "$label" \
    -e SPARK_LOCAL_IP=127.0.0.1 -e JAVA_TOOL_OPTIONS=-XX:TieredStopAtLevel=1 "$@"
}

step() {
  printf '== %s (+%ss)\n' "$1" "$(($(date +%s) - start))" >&2
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

show_fail() {
  cat "$1" >&2
  fail "$2"
}

case $flavor in plain) ;; *) fail "unsupported flavor $flavor" ;; esac

[ "$(docker image inspect -f '{{.Config.User}}' "$image")" = 185 ] || fail 'unexpected OCI user'
[ "$(docker image inspect -f '{{json .Config.Entrypoint}}' "$image")" = '["/opt/entrypoint.sh"]' ] ||
  fail 'unexpected entrypoint'
[ "$(docker image inspect -f '{{.Config.WorkingDir}}' "$image")" = /opt/spark/work-dir ] ||
  fail 'unexpected working directory'
docker image inspect -f '{{json .Config.Env}}' "$image" | grep -q '"SPARK_HOME=/opt/spark"' ||
  fail 'SPARK_HOME is not /opt/spark'
docker image inspect -f '{{json .Config.Env}}' "$image" | grep -q '"JAVA_HOME=/usr/lib/jvm/java-21-openjdk"' ||
  fail 'JAVA_HOME is not the Java 21 runtime'

step 'image layout'
# Pass-through mode: anything other than driver or executor is exec'd as given.
[ "$(run "$image" id -u)" = 185 ] || fail 'runtime user is not 185'
[ "$(run "$image" id -g)" = 185 ] || fail 'runtime group is not 185'
run "$image" sh -c '
  set -e
  test -x /opt/decom.sh
  test -x /usr/bin/tini
  test -x /usr/bin/python3
  test -f /opt/spark/RELEASE
  test -d /opt/spark/python/pyspark
  ls /opt/spark/python/lib/py4j-*-src.zip /opt/spark/python/lib/pyspark.zip >/dev/null
  touch /opt/spark/work-dir/probe
  rm /opt/spark/work-dir/probe
  if ls /opt/spark/jars | grep -E "^(hive-exec|hive-metastore|spark-hive|spark-yarn)"; then exit 1; fi
  ls /opt/spark/jars/spark-kubernetes_*.jar >/dev/null
' || fail 'unexpected image layout'
# Group 0 can write the working directory, also for a UID without a passwd entry.
run -u 1000770000:0 "$image" sh -c 'touch probe; rm probe' ||
  fail 'group 0 cannot write the working directory'

step 'java -version'
run "$image" java -version >"$work/java.log" 2>&1 || show_fail "$work/java.log" 'java -version failed'
grep -q 'version "21' "$work/java.log" || show_fail "$work/java.log" 'Java 21 is missing'

step 'spark-submit --version'
run "$image" spark-submit --version >"$work/version.log" 2>&1 ||
  show_fail "$work/version.log" 'spark-submit --version failed'
grep -q "version $expected_version\$" "$work/version.log" ||
  show_fail "$work/version.log" "spark-submit does not report version $expected_version"

check_pi() {
  value=$(sed -n 's/^Pi is roughly \([0-9.]*\)$/\1/p' "$1")
  [ -n "$value" ] || show_fail "$1" "$2: no Pi result line"
  awk -v pi="$value" 'BEGIN { exit !(pi > 3.10 && pi < 3.18) }' || show_fail "$1" "$2: Pi estimate $value is off"
}

step 'SparkPi local mode'
# SparkPi in local mode, through the pass-through entrypoint.
run "$image" /opt/spark/bin/spark-submit --master 'local[1]' \
  --class org.apache.spark.examples.SparkPi /opt/spark/examples/jars/spark-examples.jar 2 \
  >"$work/pi.log" 2>&1 || show_fail "$work/pi.log" 'SparkPi failed'
check_pi "$work/pi.log" SparkPi

step 'driver mode'
# The driver mode the Spark Kubernetes backend (and the Spark operator) invokes:
# spark-submit in client mode under tini, bound to the pod address. The backend
# also sets spark.driver.host (the driver service); here both are loopback.
run -e SPARK_DRIVER_BIND_ADDRESS=127.0.0.1 "$image" driver --master 'local[1]' \
  --conf spark.driver.host=127.0.0.1 \
  --class org.apache.spark.examples.SparkPi /opt/spark/examples/jars/spark-examples.jar 2 \
  >"$work/driver.log" 2>&1 || show_fail "$work/driver.log" 'driver-mode SparkPi failed'
check_pi "$work/driver.log" 'driver-mode SparkPi'

step 'PySpark'
# PySpark: the bundled pi.py, then a DataFrame round trip through Parquet and JSON
# (Hadoop file system, parquet-jackson and Jackson) and a managed table in the
# default spark-warehouse, from the default working directory.
# shellcheck disable=SC2016 # expanded by the container shell
run "$image" sh -c '
  set -e
  [ "$(pwd)" = /opt/spark/work-dir ]
  spark-submit --master "local[1]" /opt/spark/examples/src/main/python/pi.py 2
  cat > roundtrip.py <<EOF
from pyspark.sql import SparkSession
spark = SparkSession.builder.appName("verity-roundtrip").getOrCreate()
df = spark.range(100).selectExpr("id", "id % 7 AS bucket")
df.write.parquet("/tmp/out/parquet")
df.write.json("/tmp/out/json")
total = spark.read.parquet("/tmp/out/parquet").groupBy("bucket").count().count()
rows = spark.read.json("/tmp/out/json").count()
df.write.saveAsTable("buckets")
table = spark.table("buckets").count()
print("ROUNDTRIP buckets=%d rows=%d table=%d" % (total, rows, table))
spark.stop()
EOF
  spark-submit --master "local[1]" roundtrip.py
  [ -d spark-warehouse/buckets ]
' >"$work/pyspark.log" 2>&1 || show_fail "$work/pyspark.log" 'PySpark run failed'
check_pi "$work/pyspark.log" 'PySpark pi.py'
grep -qx 'ROUNDTRIP buckets=7 rows=100 table=100' "$work/pyspark.log" ||
  show_fail "$work/pyspark.log" 'PySpark Parquet/JSON/table round trip returned the wrong result'

step 'negative cases'
# Negative cases: a missing main class fails, the Hive SQL CLI is not built in, and
# a UID without a passwd entry is rejected by Hadoop's login (Wolfi has no
# nss_wrapper for the entrypoint's fake-passwd fallback).
# A timeout (124) is a hang, not the expected failure.
expect_failure() {
  log=$1
  shift
  status=0
  run "$@" >"$log" 2>&1 || status=$?
  [ "$status" -ne 124 ] || show_fail "$log" "timed out instead of failing: $*"
  [ "$status" -ne 0 ]
}
expect_failure "$work/missing.log" "$image" spark-submit --master 'local[1]' \
  --class org.example.Missing /opt/spark/examples/jars/spark-examples.jar ||
  fail 'spark-submit with a missing class succeeded'
grep -q 'Failed to load class org.example.Missing' "$work/missing.log" ||
  show_fail "$work/missing.log" 'missing class did not fail clearly'
expect_failure "$work/hive.log" "$image" spark-sql -e 'SELECT 1' ||
  fail 'spark-sql (Hive) unexpectedly available'
grep -q 'You need to build Spark with -Phive' "$work/hive.log" || show_fail "$work/hive.log" 'spark-sql did not fail clearly'
expect_failure "$work/uid.log" -u 1000770000:0 -e HOME=/tmp "$image" spark-submit --master 'local[1]' \
  --class org.apache.spark.examples.SparkPi /opt/spark/examples/jars/spark-examples.jar 1 ||
  fail 'a UID without a passwd entry unexpectedly ran Spark'
grep -q 'Invalid UID, could not determine effective user' "$work/uid.log" ||
  show_fail "$work/uid.log" 'unknown UID did not fail clearly'

printf 'SMOKE PASS image=%s\n' "$image"
