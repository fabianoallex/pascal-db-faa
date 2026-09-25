#!/bin/sh
# Runs the integration (contract) suite on Linux: a Firebird server container
# plus an FPC container on a private Docker network. The FPC container
# installs the Firebird client (libfbclient2 from Debian), builds the suite
# with plain fpc and runs it with heaptrc. Everything is removed at the end,
# even on failure. Acceptance: 0 errors, 0 failures, 0 unfreed blocks.
#
# FPC_IMAGE: an image with FPC 3.2.2 (default: fpc322-bookworm)
# FB_IMAGE:  Firebird server image (default: firebirdsql/firebird:5)
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FPC_IMAGE="${FPC_IMAGE:-fpc322-bookworm}"
FB_IMAGE="${FB_IMAGE:-firebirdsql/firebird:5}"
NET=pascaldb-it-net
FB=pascaldb-it-fb
MOUNT="$ROOT"
command -v cygpath >/dev/null 2>&1 && MOUNT="$(cygpath -w "$ROOT")"

cleanup() {
  docker rm -f "$FB" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

cd "$ROOT"
python tools/gen_fpc_mirror.py --check

docker network create "$NET" >/dev/null
docker run -d --name "$FB" --network "$NET" -e FIREBIRD_ROOT_PASSWORD=masterkey "$FB_IMAGE" >/dev/null

MSYS_NO_PATHCONV=1 docker run --rm --network "$NET" -v "$MOUNT:/src:ro" \
  -e PASCALDB_IT_HOST="$FB" \
  -e PASCALDB_IT_DATABASE=/var/lib/firebird/data/pascaldb_it.fdb \
  -e PASCALDB_IT_PASSWORD=masterkey \
  "$FPC_IMAGE" bash -c '
  set -e
  apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq libfbclient2 >/dev/null 2>&1
  export PASCALDB_IT_CLIENT="$(ls /usr/lib/*/libfbclient.so.2 | head -1)"
  mkdir -p /t/u && cp -r /src/src /src/adapters /src/tests /t/
  cd /t/tests/Integration/fpc
  fpc -v0 -Mdelphi -Fu/t/src -Fi/t/src -Fu/t/adapters/sqldb -Fu.. -FU/t/u -gh -gl -o/t/runner \
    PascalDbIntegrationTestsFpc.lpr > /t/build.log 2>&1 || { grep -iE "error|fatal" /t/build.log | head -30; exit 1; }
  for i in $(seq 1 60); do (echo > /dev/tcp/$PASCALDB_IT_HOST/3050) 2>/dev/null && break; sleep 1; done
  cd /t
  HEAPTRC="log=/t/heap.txt" ./runner --all --format=plain > /t/run.log 2>&1 || true
  grep -E "^Number of" /t/run.log
  grep "unfreed" /t/heap.txt
  grep -A4 "Message:" /t/run.log | head -60 || true
  grep -qE "^Number of errors: +0$" /t/run.log && grep -qE "^Number of failures: +0$" /t/run.log \
    && grep -qE "^0 unfreed memory blocks" /t/heap.txt'
