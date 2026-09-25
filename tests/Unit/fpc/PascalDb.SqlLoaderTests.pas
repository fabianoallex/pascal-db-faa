unit PascalDb.SqlLoaderTests;

{$mode delphi}{$H+}

{ ARQUIVO GERADO por tools/gen_fpc_mirror.py a partir de
  tests/Unit/PascalDb.SqlLoaderTests.pas (DUnitX). Não edite à mão: edite o mestre DUnitX
  e rode o script de novo. }

{ Testes do processamento de templates SQL (TSQLResult, em
  PascalDb.SqlLoader): ProcessTag mantendo e removendo blocos, tags
  repetidas, espaços extras na tag, remoção de COMMENTS e de tags residuais,
  ReplaceLiteral, ApplyOperator e ApplyFilter. Não cobre o carregamento de
  resource.

  Mestre DUnitX, escrito no dialeto de asserts do FPCUnit (TAssert.*, via
  PascalDb.DUnitXCompat). O espelho em tests/Unit/fpc é gerado a partir do
  mestre por tools/gen_fpc_mirror.py — edite só o mestre. }

interface

uses
  fpcunit, testregistry,
  SysUtils,
  PascalDb.SqlLoader;

type
  TSQLLoaderTests = class(TTestCase)
  published
    { ProcessTag: remove o bloco quando Keep=False }
    procedure Test_ProcessTag_False_RemoveBloco;

    { ProcessTag: mantém o conteúdo e remove apenas as tags quando Keep=True }
    procedure Test_ProcessTag_True_MantemConteudo;

    { GetSQL: tags não processadas são removidas automaticamente }
    procedure Test_GetSQL_LimpaTagsResiduo;

    { ProcessTag: mesma tag aparecendo duas vezes no SQL }
    procedure Test_ProcessTag_DuasVezes_Keep;

    { GetSQL: tag COMMENTS é sempre removida }
    procedure Test_GetSQL_ComentarioRemovido;

    { ProcessTag: tag de abertura com múltiplos espaços, Keep=False }
    procedure Test_ProcessTag_MultiEspacos_False;

    { ProcessTag: tag de abertura com múltiplos espaços, Keep=True }
    procedure Test_ProcessTag_MultiEspacos_True;

    (* ReplaceLiteral: substitui ${TAG} pelo valor fornecido *)
    procedure Test_ReplaceLiteral_Simples;

    (* ApplyOperator: substitui ${TAG_OP} pelo operador *)
    procedure Test_ApplyOperator;

    { ApplyFilter: combina ProcessTag + ReplaceLiteral quando HasValue=True }
    procedure Test_ApplyFilter_ComValor;

    { ApplyFilter: remove o bloco quando HasValue=False }
    procedure Test_ApplyFilter_SemValor;
  end;

implementation

const
  SQL_TAGS =
    'SELECT * FROM CLIENTES WHERE 1=1 [FILTRO {]AND ATIVO = ''S''[} FILTRO]';

  SQL_TAGS_MULTISPACE =
    'SELECT * FROM CLIENTES WHERE 1=1 [FILTRO    {]AND ATIVO = ''S''[} FILTRO]';

  SQL_MESMA_TAG_DUAS_VEZES =
    'SELECT * FROM CLIENTES WHERE 1=1 [FILTRO {] AND 2=2 [} FILTRO] [FILTRO {] AND 3=3 [} FILTRO]';

  SQL_COMMENTS =
    'SELECT * FROM CLIENTES [COMMENTS {] Isso e um comentario [} COMMENTS]';

  SQL_LITERAL =
    'SELECT * FROM ${TABELA} WHERE CAMPO ${CAMPO_OP} :CAMPO';

{ TSQLLoaderTests }

procedure TSQLLoaderTests.Test_ProcessTag_False_RemoveBloco;
var
  LResult: string;
begin
  LResult := TSQLResult.From(SQL_TAGS).ProcessTag('FILTRO', False).SQL;
  TAssert.AssertEquals('ProcessTag(False) deve remover o bloco completamente', 'SELECT * FROM CLIENTES WHERE 1=1', Trim(LResult));
end;

procedure TSQLLoaderTests.Test_ProcessTag_True_MantemConteudo;
var
  LResult: string;
begin
  LResult := TSQLResult.From(SQL_TAGS).ProcessTag('FILTRO', True).SQL;
  TAssert.AssertEquals('ProcessTag(True) deve manter o conteúdo e remover as tags', 'SELECT * FROM CLIENTES WHERE 1=1 AND ATIVO = ''S''', Trim(LResult));
end;

procedure TSQLLoaderTests.Test_GetSQL_LimpaTagsResiduo;
var
  LResult: string;
begin
  // Sem chamar ProcessTag: GetSQL deve remover as tags residuais mantendo o conteúdo
  LResult := TSQLResult.From(SQL_TAGS).SQL;
  TAssert.AssertEquals('GetSQL deve limpar tags não processadas, mantendo o conteúdo', 'SELECT * FROM CLIENTES WHERE 1=1 AND ATIVO = ''S''', Trim(LResult));
end;

procedure TSQLLoaderTests.Test_ProcessTag_DuasVezes_Keep;
var
  LResult: string;
begin
  LResult := TSQLResult.From(SQL_MESMA_TAG_DUAS_VEZES)
    .ProcessTag('FILTRO', True)
    .SQL;
  TAssert.AssertEquals('ProcessTag(True) deve processar todas as ocorrências da mesma tag', 'SELECT * FROM CLIENTES WHERE 1=1  AND 2=2   AND 3=3', Trim(LResult));
end;

procedure TSQLLoaderTests.Test_GetSQL_ComentarioRemovido;
var
  LResult: string;
begin
  LResult := TSQLResult.From(SQL_COMMENTS).SQL;
  TAssert.AssertEquals('Bloco COMMENTS deve ser automaticamente removido por GetSQL', 'SELECT * FROM CLIENTES', Trim(LResult));
end;

procedure TSQLLoaderTests.Test_ProcessTag_MultiEspacos_False;
var
  LResult: string;
begin
  LResult := TSQLResult.From(SQL_TAGS_MULTISPACE).ProcessTag('FILTRO', False).SQL;
  TAssert.AssertEquals('ProcessTag(False) deve reconhecer tags com espaços extras antes do {]', 'SELECT * FROM CLIENTES WHERE 1=1', Trim(LResult));
end;

procedure TSQLLoaderTests.Test_ProcessTag_MultiEspacos_True;
var
  LResult: string;
begin
  LResult := TSQLResult.From(SQL_TAGS_MULTISPACE).ProcessTag('FILTRO', True).SQL;
  TAssert.AssertEquals('ProcessTag(True) deve manter conteúdo mesmo com espaços extras na tag de abertura', 'SELECT * FROM CLIENTES WHERE 1=1 AND ATIVO = ''S''', Trim(LResult));
end;

procedure TSQLLoaderTests.Test_ReplaceLiteral_Simples;
var
  LResult: string;
begin
  LResult := TSQLResult.From(SQL_LITERAL)
    .ReplaceLiteral('TABELA', 'TB_CLIENTES')
    .SQL;
  TAssert.AssertTrue('ReplaceLiteral deve substituir ${TABELA} por TB_CLIENTES', Pos('TB_CLIENTES', LResult) > 0);
  TAssert.AssertTrue('Marcador ${TABELA} não deve mais existir após ReplaceLiteral', Pos('${TABELA}', LResult) = 0);
end;

procedure TSQLLoaderTests.Test_ApplyOperator;
var
  LResult: string;
begin
  LResult := TSQLResult.From(SQL_LITERAL)
    .ApplyOperator('CAMPO', '=')
    .SQL;
  TAssert.AssertTrue('ApplyOperator deve substituir ${CAMPO_OP}', Pos('${CAMPO_OP}', LResult) = 0);
  TAssert.AssertTrue('Operador = deve ter sido inserido', Pos('= :CAMPO', LResult) > 0);
end;

procedure TSQLLoaderTests.Test_ApplyFilter_ComValor;
var
  LResult: string;
begin
  // HasValue=True: mantém o bloco e substitui o operador
  LResult := TSQLResult.From(SQL_TAGS)
    .ApplyFilter('FILTRO', '=', True)
    .SQL;
  TAssert.AssertEquals('ApplyFilter(True) deve manter o bloco FILTRO', 'SELECT * FROM CLIENTES WHERE 1=1 AND ATIVO = ''S''', Trim(LResult));
end;

procedure TSQLLoaderTests.Test_ApplyFilter_SemValor;
var
  LResult: string;
begin
  // HasValue=False: remove o bloco completamente
  LResult := TSQLResult.From(SQL_TAGS)
    .ApplyFilter('FILTRO', '=', False)
    .SQL;
  TAssert.AssertEquals('ApplyFilter(False) deve remover o bloco FILTRO', 'SELECT * FROM CLIENTES WHERE 1=1', Trim(LResult));
end;

initialization
  RegisterTest(TSQLLoaderTests);

end.
