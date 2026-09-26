#!/bin/sh
# Builds the samples on Linux FPC and runs them, SQLdb or Zeos adapter: a
# database server container plus an FPC container on a private Docker network
# (same layout as test_integration_docker.sh). Sample 01 needs no database;
# samples 02 to 05 run against the server (03 twice: every migration applies
# on the first run, none on the second; the outcomes of 04's partial updates
# and of 05's three pool phases are checked in their output). Everything is
# removed at the end, even on failure. Acceptance: every sample exits with 0
# and reports 0 unfreed blocks.
#
# ENGINE:    postgresql (default) or firebird
# ADAPTER:   sqldb (default) or zeos
# ZEOSDBO:   ADAPTER=zeos only: the ZeosLib 8 folder (the one containing
#            src/core, src/dbc, ...), mounted read-only into the FPC container
# FPC_IMAGE: an image with FPC 3.2.2 (default: fpc322-bookworm)
# FB_IMAGE:  Firebird server image (default: firebirdsql/firebird:5)
# PG_IMAGE:  PostgreSQL server image (default: postgres:17)
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="${ENGINE:-postgresql}"
ADAPTER="${ADAPTER:-sqldb}"
FPC_IMAGE="${FPC_IMAGE:-fpc322-bookworm}"
FB_IMAGE="${FB_IMAGE:-firebirdsql/firebird:5}"
PG_IMAGE="${PG_IMAGE:-postgres:17}"
NET=pascaldb-samples-net
DB=pascaldb-samples-db
MOUNT="$ROOT"
command -v cygpath >/dev/null 2>&1 && MOUNT="$(cygpath -w "$ROOT")"

case "$ENGINE" in
  postgresql)
    SERVER_IMAGE="$PG_IMAGE"; SERVER_ENV="POSTGRES_PASSWORD=postgres"; SERVER_ENV2="POSTGRES_DB=postgres"
    CLIENT_PKG=libpq5; CLIENT_GLOB='/usr/lib/*/libpq.so.5'; DB_PORT=5432
    SAMPLE_DATABASE=postgres; SAMPLE_PASSWORD=postgres ;;
  firebird)
    # The image creates FIREBIRD_DATABASE on first start (sample 02 needs an
    # existing database).
    SERVER_IMAGE="$FB_IMAGE"; SERVER_ENV="FIREBIRD_ROOT_PASSWORD=masterkey"; SERVER_ENV2="FIREBIRD_DATABASE=samples.fdb"
    CLIENT_PKG=libfbclient2; CLIENT_GLOB='/usr/lib/*/libfbclient.so.2'; DB_PORT=3050
    SAMPLE_DATABASE=/var/lib/firebird/data/samples.fdb; SAMPLE_PASSWORD=masterkey ;;
  *) echo "ENGINE must be postgresql or firebird" >&2; exit 2 ;;
esac

ZEOS_MOUNT=""
case "$ADAPTER" in
  sqldb)
    ADAPTER_OPTS="-Fu/t/adapters/sqldb" ;;
  zeos)
    [ -d "${ZEOSDBO:-}/src/dbc" ] || { echo "ADAPTER=zeos needs ZEOSDBO (the ZeosLib folder containing src/dbc)" >&2; exit 2; }
    ZEOS_MOUNT="$(cd "$ZEOSDBO" && pwd)"
    command -v cygpath >/dev/null 2>&1 && ZEOS_MOUNT="$(cygpath -w "$ZEOS_MOUNT")"
    ZEOS_MOUNT="-v $ZEOS_MOUNT:/zeos:ro"
    ADAPTER_OPTS="-dPASCALDB_SAMPLES_ZEOS -Fu/t/adapters/zeos -Fi/zeos/src"
    for d in core plain parsesql dbc component; do ADAPTER_OPTS="$ADAPTER_OPTS -Fu/zeos/src/$d"; done ;;
  *) echo "ADAPTER must be sqldb or zeos" >&2; exit 2 ;;
esac

cleanup() {
  docker rm -f "$DB" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

cd "$ROOT"
python tools/build_sql_res.py samples/03-migrations/sql samples/03-migrations/sql/MigrationsSql.res --check

docker network create "$NET" >/dev/null
docker run -d --name "$DB" --network "$NET" -e "$SERVER_ENV" -e "$SERVER_ENV2" "$SERVER_IMAGE" >/dev/null

# $ZEOS_MOUNT is unquoted on purpose: empty (no option) or "-v <dir>:/zeos:ro".
MSYS_NO_PATHCONV=1 docker run --rm --network "$NET" -v "$MOUNT:/src:ro" $ZEOS_MOUNT \
  -e PASCALDB_SAMPLE_ENGINE="$ENGINE" \
  -e PASCALDB_SAMPLE_HOST="$DB" \
  -e PASCALDB_SAMPLE_DATABASE="$SAMPLE_DATABASE" \
  -e PASCALDB_SAMPLE_PASSWORD="$SAMPLE_PASSWORD" \
  -e CLIENT_PKG="$CLIENT_PKG" -e CLIENT_GLOB="$CLIENT_GLOB" -e DB_PORT="$DB_PORT" \
  -e ADAPTER_OPTS="$ADAPTER_OPTS" \
  "$FPC_IMAGE" bash -c '
  set -e
  apt-get update -qq > /t-apt.log 2>&1 || { tail -20 /t-apt.log; exit 1; }
  apt-get install -y -qq "$CLIENT_PKG" >> /t-apt.log 2>&1 || { tail -20 /t-apt.log; exit 1; }
  export PASCALDB_SAMPLE_CLIENT="$(ls $CLIENT_GLOB 2>/dev/null | head -1)"
  [ -n "$PASCALDB_SAMPLE_CLIENT" ] || { echo "client library not installed: $CLIENT_GLOB"; tail -20 /t-apt.log; exit 1; }
  mkdir -p /t/u1 /t/u2 /t/u3 /t/u4 /t/u5 && cp -r /src/src /src/adapters /src/samples /t/
  build() { # dir program units-folder [extra options]
    cd /t/samples/$1
    fpc -v0 -Mdelphi -Fu/t/src -Fi/t/src -Fu../common -FU/t/$3 -gh -gl -o/t/$2 $4 $2.dpr > /t/build-$2.log 2>&1 \
      || { grep -iE "error|fatal" /t/build-$2.log | head -30; exit 1; }
  }
  run() { # program [arguments]
    echo "== $*"
    cd /t
    rm -f /t/heap-$1.txt # heaptrc appends to its log
    HEAPTRC="log=/t/heap-$1.txt" ./"$@" > /t/run-$1.log 2>&1 && LCODE=0 || LCODE=$?
    cat /t/run-$1.log
    grep "unfreed" /t/heap-$1.txt
    # On a leak, show where the blocks were allocated (built with -gl).
    grep -qE "^0 unfreed memory blocks" /t/heap-$1.txt || head -80 /t/heap-$1.txt
    [ "$LCODE" = 0 ] && grep -qE "^0 unfreed memory blocks" /t/heap-$1.txt
  }
  build 01-mock-repository MockRepository u1
  build 02-quickstart Quickstart u2 "$ADAPTER_OPTS"
  build 03-migrations Migrations u3 "$ADAPTER_OPTS"
  build 04-optionals Optionals u4 "$ADAPTER_OPTS"
  build 05-pool PoolUnderLoad u5 "$ADAPTER_OPTS"
  run MockRepository
  for i in $(seq 1 60); do (echo > /dev/tcp/$PASCALDB_SAMPLE_HOST/$DB_PORT) 2>/dev/null && break; sleep 1; done
  # Firebird creates the database only after the port opens: retry briefly,
  # but only while the sample cannot connect.
  for i in 1 2 3 4 5 6; do
    run Quickstart && break
    grep -q "^Could not connect" /t/run-Quickstart.log && [ $i -lt 6 ] || exit 1
    echo "(could not connect yet; retrying in 3 s)"; sleep 3
  done
  run Migrations
  grep -q "applied 5; schema version now: 5" /t/run-Migrations.log || { echo "expected 5 migrations applied"; exit 1; }
  run Migrations
  grep -q "applied 0; schema version now: 5" /t/run-Migrations.log || { echo "expected no pending migration"; exit 1; }
  run Optionals
  # Maria: renamed, phone cleared (Null), e-mail kept (Undefined).
  # Ana: e-mail set, phone kept NULL (Undefined).
  grep -qE "^  1  Maria Silva +city=Campinas +email=maria@example.com +phone=\(null\)" /t/run-Optionals.log \
    && grep -qE "^  3  Ana +city=Campinas +email=ana@example.com +phone=\(null\)" /t/run-Optionals.log \
    || { echo "unexpected result of the partial updates"; exit 1; }
  run PoolUnderLoad
  # Phase 1: nobody times out. Phase 2: three give up. Phase 3: the sweep
  # closes the two extra connections.
  grep -q "result: 6 done, 0 timed out" /t/run-PoolUnderLoad.log \
    && grep -q "result: 3 done, 3 timed out" /t/run-PoolUnderLoad.log \
    && grep -q "pool: 1 open (1 idle), max 3; since start: 3 created, 3 timeouts, 2 swept" /t/run-PoolUnderLoad.log \
    || { echo "unexpected pool behavior"; exit 1; }'
