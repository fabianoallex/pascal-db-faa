#!/bin/sh
# Everything CI runs (.github/workflows/ci.yml), also runnable locally with
# Docker: the unit suite, then the integration (contract) suite and the
# samples for the SQLdb and Zeos adapters on Firebird 5, PostgreSQL 17,
# SQLite, MySQL 8.4 and MariaDB 11.4, all on Linux FPC 3.2.2.
# Delphi Community Edition can't build headless, so the Delphi side is still
# validated in the IDE (see CLAUDE.md, "Tests").
#
# FPC image: built here from Debian bookworm's fpc package (3.2.2) and tagged
# pascaldb-fpc322, unless FPC_IMAGE names an existing one.
# ZeosLib: ZEOSDBO if set; otherwise ZeosLib 8.0.0 is downloaded from
# SourceForge into .ci/ (git-ignored), checked against a pinned SHA-256.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ZEOS_URL="https://downloads.sourceforge.net/project/zeoslib/Zeos%20Database%20Objects/zeosdbo-8.0.0-stable/zeosdbo-8.0.0-stable.zip"
ZEOS_SHA256=21398d4015e3fb43c56e9c0b3101ae2a8f9e71fa41c66f826224cee493040e92

if [ -z "${FPC_IMAGE:-}" ]; then
  FPC_IMAGE=pascaldb-fpc322
  docker build -q -t "$FPC_IMAGE" - <<'EOF' >/dev/null
FROM debian:bookworm
RUN apt-get update && apt-get install -y --no-install-recommends fpc && rm -rf /var/lib/apt/lists/*
EOF
fi
export FPC_IMAGE

if [ -z "${ZEOSDBO:-}" ]; then
  ZEOSDBO="$ROOT/.ci/zeosdbo-8.0.0-stable"
  if [ ! -d "$ZEOSDBO/src/dbc" ]; then
    mkdir -p .ci
    curl -fsSL -o .ci/zeos.zip "$ZEOS_URL"
    echo "$ZEOS_SHA256  .ci/zeos.zip" | sha256sum -c - >/dev/null
    rm -rf "$ZEOSDBO"
    unzip -q .ci/zeos.zip -d "$ZEOSDBO"
    rm .ci/zeos.zip
  fi
fi
export ZEOSDBO

echo "== unit suite"
sh tools/test_fpc_docker.sh
for ADAPTER in sqldb zeos; do
  for ENGINE in firebird postgresql sqlite; do
    echo "== integration: $ADAPTER on $ENGINE"
    ADAPTER=$ADAPTER ENGINE=$ENGINE sh tools/test_integration_docker.sh
  done
done
# MySQL and MariaDB: MariaDB Connector/C for both servers.
for ADAPTER in sqldb zeos; do
  for ENGINE in mysql mariadb; do
    echo "== integration: $ADAPTER on $ENGINE"
    ADAPTER=$ADAPTER ENGINE=$ENGINE sh tools/test_integration_docker.sh
  done
done
for ADAPTER in sqldb zeos; do
  for ENGINE in firebird postgresql sqlite mysql mariadb; do
    echo "== samples: $ADAPTER on $ENGINE"
    ADAPTER=$ADAPTER ENGINE=$ENGINE sh tools/test_samples_docker.sh
  done
done
