# pascal-db-faa

Camada de acesso a banco de dados para **Delphi e Lazarus/FPC com o mesmo código**
(dual-compiler).

- Contratos agnósticos de driver: `IDBFactory`, `IDBConnection`, `ITransaction`,
  `IScopeTransaction`, `IQuery`, `IQueryResult`, `IParams`.
- Pool de conexões com ramp-up, limite, espera, varredura de ociosas, descarte de conexão
  quebrada e eventos/snapshot para métricas.
- Migrations versionadas.
- SQL em templates com tags (`[TAG {] ... [} TAG]`, `${LITERAL}`).
- Tipos opcionais/nuláveis (`IOptXxx`, `INullXxx`, `IOptNullXxx`) integrados aos parâmetros.
- `TMockDBFactory`: mock completo para testar repositórios sem banco.

Os drivers ficam em adapters separados. Planejados: FireDAC (só Delphi), Zeos (dual) e SQLdb
(só Lazarus). Qualquer outro driver entra implementando `IDBComponentProvider`/`IDBFactory`.

## Estado

Extraído do núcleo de banco do `delphi-api-infra-faa` (commit `aa49f2b`). O núcleo compila no
FPC 3.2.2 (Lazarus 4.0) e no Delphi 12 CE: 158/158 testes nos dois, 0 leaks nos dois
(heaptrc / FastMM). Os adapters ainda não existem.

## Estrutura

```
src/                    núcleo (todas as units incluem pascaldb.inc)
packages/               pascal_db_faa.lpk (Lazarus)
tests/Unit/             testes DUnitX (mestres) + PascalDb.UnitTests.dproj
tests/Unit/fpc/         espelho FPCUnit GERADO + PascalDbUnitTestsFpc.lpi
tools/                  gen_fpc_mirror.py, test_fpc.sh
PascalDb.groupproj      grupo Delphi
PascalDb.lpg            grupo Lazarus
```

## Testes

- FPC: `sh tools/test_fpc.sh`
- Delphi: abrir `PascalDb.groupproj` e rodar `PascalDb.UnitTests` (o Community Edition não
  compila por linha de comando).

Convenções, armadilhas Delphi × FPC já encontradas e pendências: ver `CLAUDE.md`.

## Licença

MIT.
