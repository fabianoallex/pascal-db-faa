#!/bin/sh
# Runs the integration (contract) suite on Linux, SQLdb or Zeos adapter: a
# database server container plus an FPC container on a private Docker network
# (SQLite needs no server: its database is a file inside the FPC container).
# The FPC container installs the client library from Debian (libfbclient2,
# libpq5 or libsqlite3-0), builds the suite with plain fpc and runs it with
# heaptrc. Everything is removed at the end, even on failure. Acceptance:
# 0 errors, 0 failures, 0 unfreed blocks.
#
# ENGINE:    firebird (default), postgresql or sqlite
# ADAPTER:   sqldb (default) or zeos
# ZEOSDBO:   ADAPTER=zeos only: the ZeosLib 8 folder (the one containing
#            src/core, src/dbc, ...), mounted read-only into the FPC container
# FPC_IMAGE: an image with FPC 3.2.2 (default: fpc322-bookworm)
# FB_IMAGE:  Firebird server image (default: firebirdsql/firebird:5)
# PG_IMAGE:  PostgreSQL server image (default: postgres:17)
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="${ENGINE:-firebird}"
ADAPTER="${ADAPTER:-sqldb}"
FPC_IMAGE="${FPC_IMAGE:-fpc322-bookworm}"
FB_IMAGE="${FB_IMAGE:-firebirdsql/firebird:5}"
PG_IMAGE="${PG_IMAGE:-postgres:17}"
NET=pascaldb-it-net
DB=pascaldb-it-db
MOUNT="$ROOT"
command -v cygpath >/dev/null 2>&1 && MOUNT="$(cygpath -w "$ROOT")"

case "$ENGINE" in
  firebird)
    SERVER_IMAGE="$FB_IMAGE"; SERVER_ENV="FIREBIRD_ROOT_PASSWORD=masterkey"
    CLIENT_PKG=libfbclient2; CLIENT_GLOB='/usr/lib/*/libfbclient.so.2'; DB_PORT=3050
    IT_DATABASE=/var/lib/firebird/data/pascaldb_it.fdb; IT_PASSWORD=masterkey ;;
  postgresql)
    SERVER_IMAGE="$PG_IMAGE"; SERVER_ENV="POSTGRES_PASSWORD=postgres"
    CLIENT_PKG=libpq5; CLIENT_GLOB='/usr/lib/*/libpq.so.5'; DB_PORT=5432
    IT_DATABASE=pascaldb_it; IT_PASSWORD=postgres ;;
  sqlite)
    SERVER_IMAGE=""; SERVER_ENV=""
    CLIENT_PKG=libsqlite3-0; CLIENT_GLOB='/usr/lib/*/libsqlite3.so.0'; DB_PORT=""
    IT_DATABASE=/t/pascaldb_it.sqlite; IT_PASSWORD="" ;;
  *) echo "ENGINE must be firebird, postgresql or sqlite" >&2; exit 2 ;;
esac

ZEOS_MOUNT=""
case "$ADAPTER" in
  sqldb)
    RUNNER_DIR=fpc; RUNNER=PascalDbIntegrationTestsFpc.lpr
    ADAPTER_OPTS="-Fu/t/adapters/sqldb" ;;
  zeos)
    [ -d "${ZEOSDBO:-}/src/dbc" ] || { echo "ADAPTER=zeos needs ZEOSDBO (the ZeosLib folder containing src/dbc)" >&2; exit 2; }
    ZEOS_MOUNT="$(cd "$ZEOSDBO" && pwd)"
    command -v cygpath >/dev/null 2>&1 && ZEOS_MOUNT="$(cygpath -w "$ZEOS_MOUNT")"
    ZEOS_MOUNT="-v $ZEOS_MOUNT:/zeos:ro"
    RUNNER_DIR=fpc-zeos; RUNNER=PascalDbIntegrationTestsZeosFpc.lpr
    ADAPTER_OPTS="-dPASCALDB_IT_ZEOS -Fu/t/adapters/zeos -Fu../fpc -Fi/zeos/src"
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
python tools/gen_fpc_mirror.py --check

docker network create "$NET" >/dev/null
[ -z "$SERVER_IMAGE" ] || docker run -d --name "$DB" --network "$NET" -e "$SERVER_ENV" "$SERVER_IMAGE" >/dev/null

# $ZEOS_MOUNT is unquoted on purpose: empty (no option) or "-v <dir>:/zeos:ro".
MSYS_NO_PATHCONV=1 docker run --rm --network "$NET" -v "$MOUNT:/src:ro" $ZEOS_MOUNT \
  -e PASCALDB_IT_ENGINE="$ENGINE" \
  -e PASCALDB_IT_HOST="$DB" \
  -e PASCALDB_IT_DATABASE="$IT_DATABASE" \
  -e PASCALDB_IT_PASSWORD="$IT_PASSWORD" \
  -e CLIENT_PKG="$CLIENT_PKG" -e CLIENT_GLOB="$CLIENT_GLOB" -e DB_PORT="$DB_PORT" \
  -e RUNNER_DIR="$RUNNER_DIR" -e RUNNER="$RUNNER" -e ADAPTER_OPTS="$ADAPTER_OPTS" \
  "$FPC_IMAGE" bash -c '
  set -e
  apt-get update -qq > /t-apt.log 2>&1 || { tail -20 /t-apt.log; exit 1; }
  apt-get install -y -qq "$CLIENT_PKG" >> /t-apt.log 2>&1 || { tail -20 /t-apt.log; exit 1; }
  export PASCALDB_IT_CLIENT="$(ls $CLIENT_GLOB 2>/dev/null | head -1)"
  [ -n "$PASCALDB_IT_CLIENT" ] || { echo "client library not installed: $CLIENT_GLOB"; tail -20 /t-apt.log; exit 1; }
  echo "client: $PASCALDB_IT_CLIENT"
  mkdir -p /t/u && cp -r /src/src /src/adapters /src/tests /t/
  cd /t/tests/Integration/$RUNNER_DIR
  fpc -v0 -Mdelphi -Fu/t/src -Fi/t/src $ADAPTER_OPTS -Fu.. -FU/t/u -gh -gl -o/t/runner \
    $RUNNER > /t/build.log 2>&1 || { grep -iE "error|fatal" /t/build.log | head -30; exit 1; }
  if [ -n "$DB_PORT" ]; then
    for i in $(seq 1 60); do (echo > /dev/tcp/$PASCALDB_IT_HOST/$DB_PORT) 2>/dev/null && break; sleep 1; done
  fi
  cd /t
  HEAPTRC="log=/t/heap.txt" ./runner --all --format=plain > /t/run.log 2>&1 || true
  grep -E "^Number of" /t/run.log
  grep "unfreed" /t/heap.txt
  grep -A4 "Message:" /t/run.log | head -60 || true
  grep -qE "^Number of errors: +0$" /t/run.log && grep -qE "^Number of failures: +0$" /t/run.log \
    && grep -qE "^0 unfreed memory blocks" /t/heap.txt'
