#!/bin/sh
# Regenera os espelhos FPCUnit a partir dos mestres DUnitX, compila e roda a
# suite unitaria no FPC. Criterio de aceite: 0 errors, 0 failures e
# "0 unfreed memory blocks" (heaptrc).
#
# O lado Delphi nao tem equivalente por linha de comando: o Delphi Community
# Edition nao compila fora da IDE (dcc32 imprime "This version of the product
# does not support command line compiling." e sai com codigo 0). Rode
# tests\Unit\PascalDb.UnitTests.dproj pela IDE.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAZBUILD="${LAZBUILD:-lazbuild}"
command -v "$LAZBUILD" >/dev/null 2>&1 || LAZBUILD=/c/lazarus4.0/lazbuild.exe

cd "$ROOT"
python tools/gen_fpc_mirror.py
cd tests/Unit/fpc
if ! "$LAZBUILD" -B PascalDbUnitTestsFpc.lpi > build.log 2>&1; then
  grep -E "Error|Fatal" build.log | grep -v "generics\." | head -30
  exit 1
fi
./PascalDbUnitTestsFpc.exe --all --format=plain > run.log 2>&1 || true
grep -E "^Number of|unfreed" run.log
grep -qE "^Number of errors: +0$" run.log && grep -qE "^Number of failures: +0$" run.log && grep -qE "^0 unfreed memory blocks" run.log
