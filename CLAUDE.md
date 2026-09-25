# pascal-db-faa — Guia para agentes de IA

Camada de acesso a banco de dados **dual-compiler** (Delphi + Lazarus/FPC): contratos
agnósticos (`IDBFactory`/`IQuery`/`IParams`), pool de conexões, migrations, SQL em templates
com tags, tipos opcionais/nuláveis e um mock completo para testes. Os drivers de conexão
ficam fora do núcleo, em adapters.

Para as regras gerais de dual-compiler (anatomia do projeto, `.inc`, testes espelhados, CI),
use a skill `dual-compiler-delphi-lazarus`. Este arquivo registra só o que é específico
daqui.

---

## Origem: extraído do delphi-api-infra-faa

O núcleo saiu de `delphi-api-infra-faa` (`src/Db/*` + as dependências em `src/Common`), no
commit **`aa49f2b` (2026-08-25)**. Os dois repositórios são **independentes**: correções
feitas lá depois desse commit (principalmente no pool, que era a área mais ativa) **não
chegam aqui sozinhas**. Se o delphi-api-infra-faa passar a consumir esta lib (decisão em
aberto), essa divergência some; até lá, compare com `git log aa49f2b..HEAD -- src/Db
src/Common/Common.Optionals.pas` do lado de lá antes de assumir que os dois estão iguais.

| Aqui | Lá |
|---|---|
| `PascalDb.Interfaces` | `Db.Interfaces` |
| `PascalDb.Pool` | `Db.Connection.Pool` |
| `PascalDb.Migrations` | `Db.Migrations` |
| `PascalDb.SqlLoader` / `SqlDialect` / `Registry` / `Mock` | `Db.SqlLoader` / `Db.SqlDialect` / `Db.Adapters.Registry` / `Db.Mock` |
| `PascalDb.Optionals` / `ClockCache` / `SystemContext` / `SafeLog` | `Common.*` de mesmo nome |
| `PascalDb.Threading` | — (novo: atomics + tick portáveis) |

O prefixo `PascalDb.*` é obrigatório: `Db.*` colidiria com a unit `db` do FPC (base do
SQLdb) e com as próprias units do delphi-api-infra-faa, se as duas libs estiverem no mesmo
search path.

---

## Regras de código (valem para toda unit em `src/`)

- **Toda unit inclui `{$I pascaldb.inc}` logo após `unit ...;`.** O `.inc` liga
  `{$MODE DELPHI}{$H+}` no FPC e normaliza `PASCALDB_WINDOWS`.
- **`uses` sem namespace** (`SysUtils`, `Generics.Collections`), nunca `System.SysUtils`. O
  Delphi resolve pelo `DCC_Namespace` do projeto; o FPC 3.2.2 não tem as units com ponto.
  Unit exclusiva do Delphi fica dentro de `{$IFNDEF FPC}` e com o nome completo
  (`Winapi.Windows`).
- **Nada de métodos anônimos** (`TThread.CreateAnonymousThread`, closures em
  `TEqualityComparer.Construct`, etc.): o FPC 3.2.2 estável não tem. Use subclasse de
  `TThread` ou função/método nomeado.
- **Callback público é `PASCALDB_FUNCREFS`** (ver `pascaldb.inc`): o tipo é
  `reference to` no Delphi e `of object` no FPC. O subconjunto portável é "passe um método":
  compila nos dois. Quem é só Delphi continua podendo passar closure. Exemplo real:
  `TPoolEventProc`, `TMigrationEventProc`.
- **Atomics e tempo monotônico só via `PascalDb.Threading`** (`PdbAtomicInc`,
  `PdbAtomicInc64`, `PdbAtomicRead64`, `PdbTickMs`). `TInterlocked` e `TStopwatch` não existem
  no FPC.
- **Nunca `TDictionary.Create(AComparer)` com `AComparer` possivelmente `nil`** (ver
  armadilha 1 abaixo).
- **Comentário de topo em toda unit, programa e teste**, entre `unit X;` (+ `{$I
  pascaldb.inc}`) e `interface`/`uses`:

  ```pascal
  { Uma frase: o que a unit é.

    Parágrafos: por que existe, decisões, armadilhas Delphi × FPC relevantes. }
  ```

  Prosa em português com acentos (os arquivos são UTF-8 com BOM, e comentário não passa
  pelo console), sem banners (`****`, `----`) nem títulos em maiúsculas. Se o texto precisar
  citar algo com `}` (sintaxe das tags de SQL, `{$DIRETIVA}`), use `(* ... *)`: um `}` dentro
  de `{ }` fecha o comentário no meio. Nos testes, o cabeçalho diz o que a unit cobre e
  termina com a nota de mestre/espelho; o espelho FPCUnit recebe em cima o aviso de "arquivo
  gerado", vindo do gerador.

---

## Testes

- Os mestres são os arquivos **DUnitX** em `tests/Unit/*Tests.pas`, escritos no **dialeto de
  asserts do FPCUnit** (`TAssert.AssertEquals/AssertTrue/AssertFalse/Fail`). No Delphi quem
  provê isso é `tests/Unit/PascalDb.DUnitXCompat.pas`.
- **`tests/Unit/fpc/*Tests.pas` são gerados**: `python tools/gen_fpc_mirror.py`. Nunca edite
  esses arquivos à mão. O gerador troca só a declaração das fixtures e o registro; o corpo
  sai byte a byte igual. `--check` falha se algum espelho estiver desatualizado.
- **Rodar no FPC:** `sh tools/test_fpc.sh` (regenera os espelhos, compila com `lazbuild` e
  roda). **No Delphi:** abrir `PascalDb.groupproj` na IDE e rodar
  `tests/Unit/PascalDb.UnitTests.dproj`. O Delphi Community Edition não compila por linha de
  comando: `dcc32` imprime "This version of the product does not support command line
  compiling." e **sai com código 0**. Não interprete isso como sucesso.
- **Critério de aceite:** todos os testes verdes **e 0 leaks nos dois lados** (heaptrc no FPC,
  `ReportMemoryLeaksOnShutdown` no Delphi).
- Ponto flutuante **sempre com delta explícito** (`AssertEquals(E, A, 0)` para exato). Ver
  armadilha 5.
- `python ../skills/dual-compiler-delphi-lazarus/scripts/verify_test_mirrors.py --root .
  --ignore-glob /lib/` é uma segunda checagem independente do gerador.

---

## Adapters (planejado)

O núcleo não conhece nenhum driver. Os adapters de referência, cada um no seu pacote:

| Adapter | Compilador | Status |
|---|---|---|
| FireDAC | só Delphi | a portar do `Db.Adapters.FireDAC` original |
| Zeos | dual | a escrever (Zeos ainda não instalado nesta máquina) |
| SQLdb | só Lazarus | a escrever |

Um adapter de terceiros implementa `IDBComponentProvider`/`IDBFactory` e se registra em
`TDBRegistry`: o núcleo nunca precisa mudar para aceitar um driver novo.

---

## Pendências conhecidas

- **`TSQLLoader` está preso a resource** (`FindResource`/`RT_RCDATA`, `.rc` compilado com
  `brcc32`). Compila e funciona nos dois compiladores, mas o pipeline de build dos `.rc` é
  diferente no FPC (`fpcres`/`windres`). Avaliar uma fonte de SQL plugável (resource ou
  diretório de `.sql`) antes dos adapters, que são os primeiros a precisar de SQL real.
- `TMockDBFactory.CreateSqlScript` devolve `nil` sem atribuir `Result` (herdado do original;
  o FPC avisa "Function result does not seem to be set").

---

## Armadilhas encontradas (Delphi × FPC 3.2.2)

Formato: sintoma → causa → correção. Registradas também na skill: 1–4 em
`references/rtl-gotchas.md` (seções "Generics / RTL collections", "Types" e "Resource
files"); 5–6 no bullet do compat adapter em `SKILL.md` ("Mirrored tests"). Quando este repo
for publicado, trocar lá as menções "`pascal-db-faa` (not yet public)" por link.

1. **`TDictionary.Create(nil)` dá Access Violation no FPC.** Sintoma: AV em
   `FindBucketIndex` (`generics.dictionaries.inc`) no primeiro `Add`/`TryGetValue`: 30 dos 158
   testes caíram por isso, todos via `TClockCache`. Causa: o Delphi troca um comparador `nil`
   por `TEqualityComparer<T>.Default`; o `rtl-generics` do FPC guarda o `nil` e chama
   `GetHashCode` nele. Correção: `if Assigned(AComparer) then TMap.Create(AComparer) else
   TMap.Create` (`PascalDb.ClockCache`).
2. **`IEqualityComparer<T>` tem assinatura diferente**: FPC usa `constref` e hash `UInt32`;
   Delphi usa `const` e hash `Integer`. `TEqualityComparer<T>.Construct` aceita closure no
   Delphi e só função comum / `of object` no FPC. Correção: função nomeada com a assinatura
   sob `{$IFDEF FPC}`, que os dois aceitam (`SingleKeyEquals`/`SingleKeyHash` em
   `PascalDb.Optionals`).
3. **`TGuid.Empty` não existe no FPC 3.2.2** (é do `TGuidHelper` do Delphi). Correção:
   constante tipada `EMPTY_GUID: TGUID = '{00000000-...}'`.
4. **`RT_RCDATA` no FPC 3.2.2 só está no `system` em alvos não-Windows**; no Windows fica na
   unit `Windows`. Correção: constante local `{$IFDEF FPC}PChar(10){$ELSE}RT_RCDATA{$ENDIF}`
   (`MAKEINTRESOURCE(10)` em qualquer plataforma).
5. **FPCUnit não tem `AssertEquals(Double, Double)` sem delta**, e o FPC resolve a chamada
   para o overload `Currency` **sem avisar**. Sintoma: um teste comparando `TDateTime`
   passava no FPC com precisão de 4 casas decimais, enquanto o original DUnitX comparava
   `Double`. Correção: delta sempre explícito; o `PascalDb.DUnitXCompat` também não oferece
   o overload sem delta, para o mestre não compilar diferente dos dois lados.
6. **`Assert.AreEqual(string, string)` do DUnitX ignora maiúsculas por padrão.** O overload
   sem `ignoreCase` usa `fIgnoreCaseDefault`, inicializado com `true`
   (`source\DUnitX\DUnitX.Assert.pas`, linha 1355, no Delphi 12; configurável por
   `Assert.IgnoreCaseDefault`). Já documentado no `Redis.DUnitXCompat`; aqui foi conferido no
   fonte. O compat passa `False` explicitamente.
