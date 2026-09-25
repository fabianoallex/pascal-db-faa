unit PascalDb.MockTests;

{$mode delphi}{$H+}

{ ARQUIVO GERADO por tools/gen_fpc_mirror.py a partir de
  tests/Unit/PascalDb.MockTests.pas (DUnitX). Não edite à mão: edite o mestre DUnitX
  e rode o script de novo. }

{ Testes do mock de banco (PascalDb.Mock): TMockQueryResult (linhas, colunas,
  nulos, coluna inexistente), TMockParams (todos os tipos, inclusive
  IOptXxx/INullXxx/IOptNullXxx), TMockSQLLoader e TMockDBFactory (respostas
  registradas por chave, execuções gravadas, erro descritivo para chave sem
  resposta).

  Mestre DUnitX, escrito no dialeto de asserts do FPCUnit (TAssert.*, via
  PascalDb.DUnitXCompat). O espelho em tests/Unit/fpc é gerado a partir do
  mestre por tools/gen_fpc_mirror.py — edite só o mestre. }

interface

uses
  fpcunit, testregistry,
  SysUtils,
  Variants,
  PascalDb.Optionals,
  PascalDb.Interfaces,
  PascalDb.SqlLoader,
  PascalDb.Mock;

type
  TMockQueryResultTests = class(TTestCase)
  published
    procedure Empty_IsEmpty_True;
    procedure Empty_Eof_True;
    procedure SingleRow_IsEmpty_False;
    procedure SingleRow_FieldCount;
    procedure SingleRow_ReadValues;
    procedure SingleRow_Eof_AfterNext;
    procedure MultiRows_RecordCount;
    procedure MultiRows_CursorNavigation;
    procedure MultiRows_GetNullableString_Null;
    procedure MultiRows_ColumnNameCaseInsensitive;
    procedure UnknownColumn_Raises;
  end;

  TMockParamsTests = class(TTestCase)
  published
    procedure SetGetString;
    procedure SetGetInteger;
    procedure SetGetInt64;
    procedure SetGetBoolean;
    procedure SetGetCurrency;
    procedure SetGetDateTime;
    procedure SetOptString_HasValue_Stores;
    procedure SetOptString_Undefined_DoesNotStore;
    procedure SetNullString_Null_StoresNull;
    procedure SetNullString_WithValue_Stores;
    procedure SetOptNullString_Undefined_DoesNotStore;
    procedure SetOptNullString_Null_StoresNull;
    procedure SetOptNullString_WithValue_Stores;
    procedure KeyNormalization_CaseInsensitive;
  end;

  TMockSQLLoaderTests = class(TTestCase)
  published
    procedure GetSql_ReturnsKeyAsSQL;
    procedure GetSql_ReplaceLiteralNoOp;
    procedure GetSql_ProcessTagNoOp;
  end;

  TMockDBFactoryTests = class(TTestCase)
  published
    procedure AddResult_OpenReturnsConfiguredResult;
    procedure Open_NoResultConfigured_Raises;
    procedure ExecSql_RecordsExecution;
    procedure Open_RecordsExecution_WasOpen_True;
    procedure ExecSql_WasOpen_False;
    procedure ExecutionCount_MultipleCalls;
    procedure LastExecution_ReturnsLast;
    procedure LastExecution_UnknownKey_ReturnsNil;
    procedure RecordExecution_CapturesParams;
    procedure SqlLoader_ReturnsMockLoader;
    procedure TestConnection_ReturnsTrue;
    procedure AcquireQuery_ReturnsQuery;
  end;

implementation

{ TMockQueryResultTests }

procedure TMockQueryResultTests.Empty_IsEmpty_True;
begin
  TAssert.AssertTrue('Empty deve ser IsEmpty=True', TMockQueryResult.Empty.IsEmpty);
end;

procedure TMockQueryResultTests.Empty_Eof_True;
begin
  TAssert.AssertTrue('Empty deve ser Eof=True imediatamente', TMockQueryResult.Empty.Eof);
end;

procedure TMockQueryResultTests.SingleRow_IsEmpty_False;
var
  R: IQueryResult;
begin
  R := TMockQueryResult.SingleRow(['ID'], [42]);
  TAssert.AssertFalse('SingleRow não deve ser IsEmpty', R.IsEmpty);
end;

procedure TMockQueryResultTests.SingleRow_FieldCount;
var
  R: IQueryResult;
begin
  R := TMockQueryResult.SingleRow(['ID', 'NOME', 'ATIVO'], [1, 'Teste', True]);
  TAssert.AssertEquals('FieldCount deve ser 3', 3, R.FieldCount);
end;

procedure TMockQueryResultTests.SingleRow_ReadValues;
var
  R: IQueryResult;
begin
  R := TMockQueryResult.SingleRow(['ID', 'NOME'], [7, 'São Paulo']);
  TAssert.AssertEquals('ID deve ser 7', 7, R.GetAsInteger('ID'));
  TAssert.AssertEquals('NOME deve ser São Paulo', 'São Paulo', R.GetAsString('NOME'));
end;

procedure TMockQueryResultTests.SingleRow_Eof_AfterNext;
var
  R: IQueryResult;
begin
  R := TMockQueryResult.SingleRow(['ID'], [1]);
  TAssert.AssertFalse('Não deve ser Eof antes de Next', R.Eof);
  R.Next;
  TAssert.AssertTrue('Deve ser Eof após Next na única linha', R.Eof);
end;

procedure TMockQueryResultTests.MultiRows_RecordCount;
var
  R: IQueryResult;
begin
  R := TMockQueryResult.MultiRows(
    ['ID', 'NOME'],
    [TArray<Variant>.Create(1, 'Alpha'),
     TArray<Variant>.Create(2, 'Beta'),
     TArray<Variant>.Create(3, 'Gamma')]);
  TAssert.AssertEquals('RecordCount deve ser 3', 3, R.RecordCount);
end;

procedure TMockQueryResultTests.MultiRows_CursorNavigation;
var
  R: IQueryResult;
begin
  R := TMockQueryResult.MultiRows(
    ['ID'],
    [TArray<Variant>.Create(10),
     TArray<Variant>.Create(20)]);
  TAssert.AssertEquals('Cursor na linha 0 deve retornar 10', 10, R.GetAsInteger('ID'));
  R.Next;
  TAssert.AssertEquals('Cursor na linha 1 deve retornar 20', 20, R.GetAsInteger('ID'));
  R.Next;
  TAssert.AssertTrue('Após 2 nexts deve ser Eof', R.Eof);
end;

procedure TMockQueryResultTests.MultiRows_GetNullableString_Null;
var
  R: IQueryResult;
  V: INullString;
begin
  R := TMockQueryResult.SingleRow(['NOME'], [Null]);
  V := R.GetNullableString('NOME');
  TAssert.AssertTrue('Variant Null deve retornar INullString.IsNull=True', V.IsNull);
end;

procedure TMockQueryResultTests.MultiRows_ColumnNameCaseInsensitive;
var
  R: IQueryResult;
begin
  R := TMockQueryResult.SingleRow(['nome'], ['Valor']);
  TAssert.AssertEquals('Coluna deve ser acessível em maiúsculas', 'Valor', R.GetAsString('NOME'));
  TAssert.AssertEquals('Coluna deve ser acessível em minúsculas', 'Valor', R.GetAsString('nome'));
end;

procedure TMockQueryResultTests.UnknownColumn_Raises;
var
  R: IQueryResult;
  LRaised: Boolean;
begin
  R := TMockQueryResult.SingleRow(['ID'], [1]);
  LRaised := False;
  try
    R.GetAsString('INEXISTENTE');
  except
    on E: Exception do
      LRaised := True;
  end;
  TAssert.AssertTrue('Coluna inexistente deve lançar exceção', LRaised);
end;

{ TMockParamsTests }

procedure TMockParamsTests.SetGetString;
var
  P: IParams;
begin
  P := TMockParams.Create;
  P.SetString('NOME', 'Fabiano');
  TAssert.AssertEquals('Fabiano', P.GetString('NOME'));
end;

procedure TMockParamsTests.SetGetInteger;
var
  P: IParams;
begin
  P := TMockParams.Create;
  P.SetInteger('ID', 42);
  TAssert.AssertEquals(42, P.GetInteger('ID'));
end;

procedure TMockParamsTests.SetGetInt64;
var
  P: IParams;
begin
  P := TMockParams.Create;
  P.SetInt64('BIG', 9999999999);
  TAssert.AssertEquals(Int64(9999999999), P.GetInt64('BIG'));
end;

procedure TMockParamsTests.SetGetBoolean;
var
  P: IParams;
begin
  P := TMockParams.Create;
  P.SetBoolean('ATIVO', True);
  TAssert.AssertTrue(P.GetBoolean('ATIVO'));
end;

procedure TMockParamsTests.SetGetCurrency;
var
  P: IParams;
  V: Currency;
begin
  P := TMockParams.Create;
  P.SetCurrency('PRECO', 19.99);
  V := P.GetCurrency('PRECO');
  TAssert.AssertEquals('Valor Currency deve ser preservado', Currency(19.99), V);
end;

procedure TMockParamsTests.SetGetDateTime;
var
  P: IParams;
  D: TDateTime;
begin
  P := TMockParams.Create;
  D := EncodeDate(2025, 5, 26);
  P.SetDateTime('DT', D);
  TAssert.AssertEquals('TDateTime deve ser preservado', D, P.GetDateTime('DT'), 0);
end;

procedure TMockParamsTests.SetOptString_HasValue_Stores;
var
  P: IParams;
begin
  P := TMockParams.Create;
  P.SetOptString('CAMPO', TOptNullString.From('ok'));
  TAssert.AssertEquals('ok', P.GetOptString('CAMPO').Value);
end;

procedure TMockParamsTests.SetOptString_Undefined_DoesNotStore;
var
  P: IParams;
begin
  P := TMockParams.Create;
  P.SetOptString('CAMPO', TOptNullString.Undefined);
  TAssert.AssertFalse('Undefined não deve ser armazenado', P.GetOptString('CAMPO').HasValue);
end;

procedure TMockParamsTests.SetNullString_Null_StoresNull;
var
  P: IParams;
begin
  P := TMockParams.Create;
  P.SetNullString('CAMPO', TOptNullString.Null);
  TAssert.AssertTrue('Null deve ser armazenado como IsNull=True', P.GetNullString('CAMPO').IsNull);
end;

procedure TMockParamsTests.SetNullString_WithValue_Stores;
var
  P: IParams;
begin
  P := TMockParams.Create;
  P.SetNullString('CAMPO', TOptNullString.From('texto'));
  TAssert.AssertEquals('texto', P.GetNullString('CAMPO').Value);
end;

procedure TMockParamsTests.SetOptNullString_Undefined_DoesNotStore;
var
  P: IParams;
begin
  P := TMockParams.Create;
  P.SetOptNullString('CAMPO', TOptNullString.Undefined);
  TAssert.AssertFalse('Undefined não deve ser armazenado', P.GetOptNullString('CAMPO').HasValue);
end;

procedure TMockParamsTests.SetOptNullString_Null_StoresNull;
var
  P: IParams;
begin
  P := TMockParams.Create;
  P.SetOptNullString('CAMPO', TOptNullString.Null);
  TAssert.AssertTrue('OptNull Null deve ser armazenado', P.GetOptNullString('CAMPO').IsNull);
end;

procedure TMockParamsTests.SetOptNullString_WithValue_Stores;
var
  P: IParams;
begin
  P := TMockParams.Create;
  P.SetOptNullString('CAMPO', TOptNullString.From('valor'));
  TAssert.AssertEquals('valor', P.GetOptNullString('CAMPO').Value);
end;

procedure TMockParamsTests.KeyNormalization_CaseInsensitive;
var
  P: IParams;
begin
  P := TMockParams.Create;
  P.SetString('nome', 'x');
  TAssert.AssertEquals('Chave deve ser case-insensitive', 'x', P.GetString('NOME'));
  TAssert.AssertEquals('Chave deve ser case-insensitive', 'x', P.GetString('Nome'));
end;

{ TMockSQLLoaderTests }

procedure TMockSQLLoaderTests.GetSql_ReturnsKeyAsSQL;
var
  L: TMockSQLLoader;
  S: TSQLResult;
begin
  L := TMockSQLLoader.Create;
  try
    S := L.Sql['PEDIDO.FIND'];
    TAssert.AssertEquals('TMockSQLLoader deve retornar o nome da chave como SQL', 'PEDIDO.FIND', S.SQL);
  finally
    L.Free;
  end;
end;

procedure TMockSQLLoaderTests.GetSql_ReplaceLiteralNoOp;
var
  L: TMockSQLLoader;
  S: string;
begin
  L := TMockSQLLoader.Create;
  try
    S := L.Sql['PEDIDO.FIND'].ReplaceLiteral('LIMIT', '20').SQL;
    TAssert.AssertEquals('ReplaceLiteral sem ${...} no nome da chave não deve alterar nada', 'PEDIDO.FIND', S);
  finally
    L.Free;
  end;
end;

procedure TMockSQLLoaderTests.GetSql_ProcessTagNoOp;
var
  L: TMockSQLLoader;
  S: string;
begin
  L := TMockSQLLoader.Create;
  try
    S := L.Sql['PEDIDO.FIND'].ProcessTag('SEARCH', True).SQL;
    TAssert.AssertEquals('ProcessTag sem tags no nome da chave não deve alterar nada', 'PEDIDO.FIND', S);
  finally
    L.Free;
  end;
end;

{ TMockDBFactoryTests }

procedure TMockDBFactoryTests.AddResult_OpenReturnsConfiguredResult;
var
  F: TMockDBFactory;
  Q: IQuery;
  Scope: IScopeTransaction;
  R: IQueryResult;
begin
  F := TMockDBFactory.Create;
  try
    F.AddResult('CIDADE.FIND', TMockQueryResult.SingleRow(['TOTAL'], [5]));
    Scope := F.GetPool.AcquireQuery(Q);
    Q.SetSql('CIDADE.FIND');
    R := Q.Open;
    TAssert.AssertTrue('Open deve retornar IQueryResult configurado', Assigned(R));
    TAssert.AssertEquals(5, R.GetAsInteger('TOTAL'));
  finally
    F.Free;
  end;
end;

procedure TMockDBFactoryTests.Open_NoResultConfigured_Raises;
var
  F: TMockDBFactory;
  Q: IQuery;
  Scope: IScopeTransaction;
  LRaised: Boolean;
begin
  F := TMockDBFactory.Create;
  try
    Scope := F.GetPool.AcquireQuery(Q);
    Q.SetSql('NAO.EXISTE');
    LRaised := False;
    try
      Q.Open;
    except
      on E: Exception do
        LRaised := True;
    end;
    TAssert.AssertTrue('Open sem AddResult deve lançar exceção descritiva', LRaised);
  finally
    F.Free;
  end;
end;

procedure TMockDBFactoryTests.ExecSql_RecordsExecution;
var
  F: TMockDBFactory;
  Q: IQuery;
  Scope: IScopeTransaction;
begin
  F := TMockDBFactory.Create;
  try
    Scope := F.GetPool.AcquireQuery(Q);
    Q.SetSql('CIDADE.INSERT');
    Q.Params.SetString('NOME', 'Curitiba');
    Q.ExecSql;
    TAssert.AssertEquals('ExecSql deve registrar 1 execução', 1, F.ExecutionCount('CIDADE.INSERT'));
    TAssert.AssertEquals('Curitiba', F.LastExecution('CIDADE.INSERT').AsString('NOME'));
  finally
    F.Free;
  end;
end;

procedure TMockDBFactoryTests.Open_RecordsExecution_WasOpen_True;
var
  F: TMockDBFactory;
  Q: IQuery;
  Scope: IScopeTransaction;
begin
  F := TMockDBFactory.Create;
  try
    F.AddResult('X.FIND', TMockQueryResult.Empty);
    Scope := F.GetPool.AcquireQuery(Q);
    Q.SetSql('X.FIND');
    Q.Open;
    TAssert.AssertTrue('Open deve registrar WasOpen=True', F.LastExecution('X.FIND').WasOpen);
  finally
    F.Free;
  end;
end;

procedure TMockDBFactoryTests.ExecSql_WasOpen_False;
var
  F: TMockDBFactory;
  Q: IQuery;
  Scope: IScopeTransaction;
begin
  F := TMockDBFactory.Create;
  try
    Scope := F.GetPool.AcquireQuery(Q);
    Q.SetSql('X.DEL');
    Q.ExecSql;
    TAssert.AssertFalse('ExecSql deve registrar WasOpen=False', F.LastExecution('X.DEL').WasOpen);
  finally
    F.Free;
  end;
end;

procedure TMockDBFactoryTests.ExecutionCount_MultipleCalls;
var
  F: TMockDBFactory;
  Q: IQuery;
  Scope: IScopeTransaction;
  I: Integer;
begin
  F := TMockDBFactory.Create;
  try
    F.AddResult('X.FIND', TMockQueryResult.Empty);
    for I := 1 to 3 do
    begin
      Scope := F.GetPool.AcquireQuery(Q);
      Q.SetSql('X.FIND');
      Q.Open;
    end;
    TAssert.AssertEquals('Deve contar 3 execuções', 3, F.ExecutionCount('X.FIND'));
    TAssert.AssertEquals('Chave diferente deve ser 0', 0, F.ExecutionCount('OUTRO'));
  finally
    F.Free;
  end;
end;

procedure TMockDBFactoryTests.LastExecution_ReturnsLast;
var
  F: TMockDBFactory;
  Q: IQuery;
  Scope: IScopeTransaction;
begin
  F := TMockDBFactory.Create;
  try
    Scope := F.GetPool.AcquireQuery(Q);
    Q.SetSql('X.UPD'); Q.Params.SetString('NOME', 'Primeiro'); Q.ExecSql;
    Scope := F.GetPool.AcquireQuery(Q);
    Q.SetSql('X.UPD'); Q.Params.SetString('NOME', 'Ultimo');   Q.ExecSql;
    TAssert.AssertEquals('LastExecution deve retornar a execução mais recente', 'Ultimo', F.LastExecution('X.UPD').AsString('NOME'));
  finally
    F.Free;
  end;
end;

procedure TMockDBFactoryTests.LastExecution_UnknownKey_ReturnsNil;
var
  F: TMockDBFactory;
begin
  F := TMockDBFactory.Create;
  try
    TAssert.AssertTrue('Chave inexistente deve retornar nil', not Assigned(F.LastExecution('NUNCA.EXECUTADO')));
  finally
    F.Free;
  end;
end;

procedure TMockDBFactoryTests.RecordExecution_CapturesParams;
var
  F: TMockDBFactory;
  Q: IQuery;
  Scope: IScopeTransaction;
  Ex: TMockExecution;
begin
  F := TMockDBFactory.Create;
  try
    Scope := F.GetPool.AcquireQuery(Q);
    Q.SetSql('PRODUTO.INSERT');
    Q.Params.SetString('NOME',   'Caneta');
    Q.Params.SetInteger('QTD',   10);
    Q.Params.SetCurrency('PRECO', 2.50);
    Q.ExecSql;

    Ex := F.LastExecution('PRODUTO.INSERT');
    TAssert.AssertTrue(Assigned(Ex));
    TAssert.AssertTrue('Snapshot deve ter NOME', Ex.HasParam('NOME'));
    TAssert.AssertTrue('Snapshot deve ter QTD', Ex.HasParam('QTD'));
    TAssert.AssertTrue('Snapshot deve ter PRECO', Ex.HasParam('PRECO'));
    TAssert.AssertEquals('Caneta', Ex.AsString('NOME'));
    TAssert.AssertEquals(10, Ex.AsInteger('QTD'));
    TAssert.AssertEquals('Preço deve ser preservado', Currency(2.50), Ex.AsCurrency('PRECO'));
  finally
    F.Free;
  end;
end;

procedure TMockDBFactoryTests.SqlLoader_ReturnsMockLoader;
var
  F: TMockDBFactory;
  L: TSQLLoader;
begin
  F := TMockDBFactory.Create;
  try
    L := F.SqlLoader;
    TAssert.AssertTrue('SqlLoader não deve retornar nil', Assigned(L));
    TAssert.AssertTrue('SqlLoader deve ser TMockSQLLoader', L is TMockSQLLoader);
  finally
    F.Free;
  end;
end;

procedure TMockDBFactoryTests.TestConnection_ReturnsTrue;
var
  F: TMockDBFactory;
begin
  F := TMockDBFactory.Create;
  try
    TAssert.AssertTrue('TestConnection no mock deve retornar True', F.TestConnection(nil));
  finally
    F.Free;
  end;
end;

procedure TMockDBFactoryTests.AcquireQuery_ReturnsQuery;
var
  F: TMockDBFactory;
  Q: IQuery;
  Scope: IScopeTransaction;
begin
  F := TMockDBFactory.Create;
  try
    Scope := F.GetPool.AcquireQuery(Q);
    TAssert.AssertTrue('AcquireQuery deve retornar IQuery', Assigned(Q));
    TAssert.AssertTrue('AcquireQuery deve retornar IScopeTransaction', Assigned(Scope));
    TAssert.AssertTrue('IQuery.Params não deve ser nil', Assigned(Q.Params));
  finally
    F.Free;
  end;
end;

initialization
  RegisterTest(TMockQueryResultTests);
  RegisterTest(TMockParamsTests);
  RegisterTest(TMockSQLLoaderTests);
  RegisterTest(TMockDBFactoryTests);

end.
