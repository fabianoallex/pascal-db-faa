unit PascalDb.SqlSourcesTests;

{ Tests for the SQL sources (PascalDb.SqlSources) and for TSQLLoader on top of
  them: memory, composite, directory (files written next to the test
  executable, which also covers resolving a relative root), resources (from
  tests/Unit/sql/PascalDbTestSql.res, built by tools/build_sql_res.py and
  linked by both test runners), UTF-8 decoding and the loader's cache and
  error message.

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalDb.DUnitXCompat). The mirror in tests/Unit/fpc is generated from the
  master by tools/gen_fpc_mirror.py — edit only the master. }

interface

uses
  DUnitX.TestFramework,
  PascalDb.DUnitXCompat,
  Classes,
  SysUtils,
  PascalDb.SqlSources,
  PascalDb.SqlLoader;

type
  { TCountingSqlSource
    Wraps a memory source and counts TryGetSql calls, to observe caching. }
  TCountingSqlSource = class(TInterfacedObject, ISqlSource)
  private
    FInner: ISqlSource;
    FCalls: Integer;
  public
    constructor Create(const AInner: ISqlSource);
    function TryGetSql(const ADirectory, AName: string; out ASql: string): Boolean;
    function Describe(const ADirectory, AName: string): string;
    property Calls: Integer read FCalls;
  end;

  [TestFixture]
  TSqlSourcesTests = class
  private
    FTempRoot: string;
    FTempFolder: string;
    procedure WriteFile(const ARelativePath: string; const ABytes: TBytes);
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    [Test] procedure Memory_ReturnsRegisteredSql;
    [Test] procedure Memory_IsCaseInsensitive;
    [Test] procedure Memory_UnknownReturnsFalse;
    [Test] procedure Composite_FirstHitWins;
    [Test] procedure Composite_FallsBackToNextSource;
    [Test] procedure Composite_DescribeListsEverySource;
    [Test] procedure Directory_ReadsFileUnderDirectory;
    [Test] procedure Directory_FallsBackToLowerCaseFolder;
    [Test] procedure Directory_UnknownReturnsFalse;
    [Test] procedure Directory_DropsUtf8Bom;
    [Test] procedure Directory_RelativeRootIsResolvedAgainstExecutable;
    [Test] procedure Resource_ReadsEmbeddedSql;
    [Test] procedure Resource_KeepsNonAsciiCharacters;
    [Test] procedure Resource_UnknownReturnsFalse;
    [Test] procedure Resource_NameReplacesDotsAndUpperCases;
    [Test] procedure Utf8_AsciiOnly_DecodesInAnyCodePage;
    [Test] procedure Utf8_NonAscii_RequiresUtf8CodePageOnFpc;
  end;

  [TestFixture]
  TSqlLoaderSourceTests = class
  public
    [Test] procedure Loader_UsesGivenSource;
    [Test] procedure Loader_DefaultSourceIsResource;
    [Test] procedure Loader_NotFound_RaisesWithDescription;
    [Test] procedure Loader_CachesText;
    [Test] procedure Loader_ClearCache_ReloadsFromSource;
  end;

implementation

function AsciiBytes(const AText: string): TBytes;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(AText));
  for I := 1 to Length(AText) do
    Result[I - 1] := Byte(Ord(AText[I]));
end;

function JoinBytes(const A, B: TBytes): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(A) + Length(B));
  if Length(A) > 0 then
    Move(A[0], Result[0], Length(A));
  if Length(B) > 0 then
    Move(B[0], Result[Length(A)], Length(B));
end;

function Utf8Bom: TBytes;
begin
  Result := nil;
  SetLength(Result, 3);
  Result[0] := $EF;
  Result[1] := $BB;
  Result[2] := $BF;
end;

// "SELECT 'ã→'" as UTF-8 bytes: ã = C3 A3, → = E2 86 92
function NonAsciiSqlBytes: TBytes;
var
  LTail: TBytes;
begin
  LTail := nil;
  SetLength(LTail, 6);
  LTail[0] := $C3; LTail[1] := $A3;
  LTail[2] := $E2; LTail[3] := $86; LTail[4] := $92;
  LTail[5] := Ord('''');
  Result := JoinBytes(AsciiBytes('SELECT '''), LTail);
end;

{ TCountingSqlSource }

constructor TCountingSqlSource.Create(const AInner: ISqlSource);
begin
  inherited Create;
  FInner := AInner;
end;

function TCountingSqlSource.TryGetSql(const ADirectory, AName: string; out ASql: string): Boolean;
begin
  Inc(FCalls);
  Result := FInner.TryGetSql(ADirectory, AName, ASql);
end;

function TCountingSqlSource.Describe(const ADirectory, AName: string): string;
begin
  Result := 'counting(' + FInner.Describe(ADirectory, AName) + ')';
end;

{ TSqlSourcesTests }

procedure TSqlSourcesTests.Setup;
begin
  // A folder next to the executable: exercises relative roots too.
  FTempFolder := 'sqlsrc_' + IntToStr(Random(MaxInt));
  FTempRoot := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)) + FTempFolder);
  ForceDirectories(FTempRoot);
end;

procedure TSqlSourcesTests.TearDown;

  procedure RemoveTree(const ADir: string);
  var
    LSearch: TSearchRec;
  begin
    if FindFirst(ADir + '*', faAnyFile, LSearch) = 0 then
    try
      repeat
        if (LSearch.Name = '.') or (LSearch.Name = '..') then
          Continue;
        if (LSearch.Attr and faDirectory) <> 0 then
          RemoveTree(IncludeTrailingPathDelimiter(ADir + LSearch.Name))
        else
          DeleteFile(ADir + LSearch.Name);
      until FindNext(LSearch) <> 0;
    finally
      FindClose(LSearch);
    end;
    RemoveDir(ADir);
  end;

begin
  RemoveTree(FTempRoot);
end;

procedure TSqlSourcesTests.WriteFile(const ARelativePath: string; const ABytes: TBytes);
var
  LPath: string;
  LStream: TFileStream;
begin
  LPath := FTempRoot + StringReplace(ARelativePath, '/', PathDelim, [rfReplaceAll]);
  ForceDirectories(ExtractFilePath(LPath));
  LStream := TFileStream.Create(LPath, fmCreate);
  try
    if Length(ABytes) > 0 then
      LStream.WriteBuffer(ABytes[0], Length(ABytes));
  finally
    LStream.Free;
  end;
end;

procedure TSqlSourcesTests.Memory_ReturnsRegisteredSql;
var
  LSource: ISqlSource;
  LSql: string;
begin
  LSource := TMemorySqlSource.Create.Add('FB', 'ORDER.FIND', 'SELECT 1');
  TAssert.AssertTrue('A registered SQL must be found', LSource.TryGetSql('FB', 'ORDER.FIND', LSql));
  TAssert.AssertEquals('SELECT 1', LSql);
end;

procedure TSqlSourcesTests.Memory_IsCaseInsensitive;
var
  LSource: ISqlSource;
  LSql: string;
begin
  LSource := TMemorySqlSource.Create.Add('fb', 'Order.Find', 'SELECT 1');
  TAssert.AssertTrue('Directory and name lookups must ignore case', LSource.TryGetSql('FB', 'ORDER.FIND', LSql));
end;

procedure TSqlSourcesTests.Memory_UnknownReturnsFalse;
var
  LSource: ISqlSource;
  LSql: string;
begin
  LSource := TMemorySqlSource.Create;
  TAssert.AssertFalse('An unknown SQL must not be found', LSource.TryGetSql('FB', 'NOPE', LSql));
end;

procedure TSqlSourcesTests.Composite_FirstHitWins;
var
  LSource: ISqlSource;
  LSql: string;
begin
  LSource := TCompositeSqlSource.Create([
    TMemorySqlSource.Create.Add('FB', 'X', 'first'),
    TMemorySqlSource.Create.Add('FB', 'X', 'second')]);
  TAssert.AssertTrue(LSource.TryGetSql('FB', 'X', LSql));
  TAssert.AssertEquals('The first source that has the SQL must win', 'first', LSql);
end;

procedure TSqlSourcesTests.Composite_FallsBackToNextSource;
var
  LSource: ISqlSource;
  LSql: string;
begin
  LSource := TCompositeSqlSource.Create([
    TMemorySqlSource.Create,
    TMemorySqlSource.Create.Add('FB', 'X', 'fallback')]);
  TAssert.AssertTrue(LSource.TryGetSql('FB', 'X', LSql));
  TAssert.AssertEquals('fallback', LSql);
end;

procedure TSqlSourcesTests.Composite_DescribeListsEverySource;
var
  LSource: ISqlSource;
  LText: string;
begin
  LSource := TCompositeSqlSource.Create([TMemorySqlSource.Create, TResourceSqlSource.Create]);
  LText := LSource.Describe('FB', 'ORDER.FIND');
  TAssert.AssertTrue('Describe must mention the memory source', Pos('memory FB/ORDER.FIND', LText) > 0);
  TAssert.AssertTrue('Describe must mention the resource source', Pos('resource SQL_FB_ORDER_FIND', LText) > 0);
end;

procedure TSqlSourcesTests.Directory_ReadsFileUnderDirectory;
var
  LSource: ISqlSource;
  LSql: string;
begin
  WriteFile('FB/ORDER.FIND.sql', AsciiBytes('SELECT * FROM ORDERS'));
  LSource := TDirectorySqlSource.Create(FTempRoot);
  TAssert.AssertTrue('The file must be found', LSource.TryGetSql('FB', 'ORDER.FIND', LSql));
  TAssert.AssertEquals('SELECT * FROM ORDERS', LSql);
end;

procedure TSqlSourcesTests.Directory_FallsBackToLowerCaseFolder;
var
  LSource: ISqlSource;
  LSql: string;
begin
  WriteFile('pg/ORDER.FIND.sql', AsciiBytes('SELECT 2'));
  LSource := TDirectorySqlSource.Create(FTempRoot);
  TAssert.AssertTrue('Directory PG must also match a lower-case pg folder', LSource.TryGetSql('PG', 'ORDER.FIND', LSql));
  TAssert.AssertEquals('SELECT 2', LSql);
end;

procedure TSqlSourcesTests.Directory_UnknownReturnsFalse;
var
  LSource: ISqlSource;
  LSql: string;
begin
  LSource := TDirectorySqlSource.Create(FTempRoot);
  TAssert.AssertFalse('A missing file must not be found', LSource.TryGetSql('FB', 'NOPE', LSql));
end;

procedure TSqlSourcesTests.Directory_DropsUtf8Bom;
var
  LSource: ISqlSource;
  LSql: string;
begin
  WriteFile('FB/BOM.sql', JoinBytes(Utf8Bom, AsciiBytes('SELECT 3')));
  LSource := TDirectorySqlSource.Create(FTempRoot);
  TAssert.AssertTrue(LSource.TryGetSql('FB', 'BOM', LSql));
  TAssert.AssertEquals('A leading UTF-8 BOM must be dropped', 'SELECT 3', LSql);
end;

procedure TSqlSourcesTests.Directory_RelativeRootIsResolvedAgainstExecutable;
var
  LSource: TDirectorySqlSource;
  LIntf: ISqlSource;
  LSql: string;
begin
  WriteFile('FB/REL.sql', AsciiBytes('SELECT 4'));
  LSource := TDirectorySqlSource.Create(FTempFolder);
  LIntf := LSource;
  TAssert.AssertEquals('A relative root must be resolved against the executable folder',
    FTempRoot, LSource.Root);
  TAssert.AssertTrue(LIntf.TryGetSql('FB', 'REL', LSql));
  TAssert.AssertEquals('SELECT 4', LSql);
end;

procedure TSqlSourcesTests.Resource_ReadsEmbeddedSql;
var
  LSource: ISqlSource;
  LSql: string;
begin
  LSource := TResourceSqlSource.Create;
  TAssert.AssertTrue('SQL_TESTS_SAMPLE_FIND must be embedded (tests/Unit/sql/PascalDbTestSql.res)',
    LSource.TryGetSql('TESTS', 'SAMPLE.FIND', LSql));
  TAssert.AssertEquals('SELECT 1 FROM SAMPLE', LSql);
end;

procedure TSqlSourcesTests.Resource_KeepsNonAsciiCharacters;
var
  LSource: ISqlSource;
  LSql: string;
begin
  LSource := TResourceSqlSource.Create;
  TAssert.AssertTrue(LSource.TryGetSql('TESTS', 'NON_ASCII.TEXT', LSql));
  TAssert.AssertEquals('Non-ASCII characters must survive the resource round trip',
    'SELECT ''ã→'' AS X', LSql);
end;

procedure TSqlSourcesTests.Resource_UnknownReturnsFalse;
var
  LSource: ISqlSource;
  LSql: string;
begin
  LSource := TResourceSqlSource.Create;
  TAssert.AssertFalse('An unknown resource must not be found', LSource.TryGetSql('TESTS', 'NOPE', LSql));
end;

procedure TSqlSourcesTests.Resource_NameReplacesDotsAndUpperCases;
begin
  TAssert.AssertEquals('SQL_FB_ORDER_FIND_BY_ID', TResourceSqlSource.ResourceName('fb', 'Order.Find.By_Id'));
end;

procedure TSqlSourcesTests.Utf8_AsciiOnly_DecodesInAnyCodePage;
begin
  TAssert.AssertEquals('SELECT 5', PdbUtf8BytesToString(AsciiBytes('SELECT 5'), 'test'));
end;

procedure TSqlSourcesTests.Utf8_NonAscii_RequiresUtf8CodePageOnFpc;
{$IFDEF FPC}
var
  LOldCodePage: TSystemCodePage;
  LRaised: Boolean;
{$ENDIF}
begin
  {$IFDEF FPC}
  // FPC: string is an AnsiString in the default code page; outside UTF-8 the
  // decoder must refuse non-ASCII text instead of turning it into "?".
  LOldCodePage := DefaultSystemCodePage;
  SetMultiByteConversionCodePage(1252);
  try
    LRaised := False;
    try
      PdbUtf8BytesToString(NonAsciiSqlBytes, 'test');
    except
      on E: ESqlSourceException do
        LRaised := True;
    end;
  finally
    SetMultiByteConversionCodePage(LOldCodePage);
  end;
  TAssert.AssertTrue('Non-ASCII SQL outside a UTF-8 code page must raise ESqlSourceException', LRaised);
  {$ELSE}
  // Delphi: string is UTF-16, there is no code page to guard.
  TAssert.AssertEquals('SELECT ''ã→''', PdbUtf8BytesToString(NonAsciiSqlBytes, 'test'));
  {$ENDIF}
end;

{ TSqlLoaderSourceTests }

procedure TSqlLoaderSourceTests.Loader_UsesGivenSource;
var
  LLoader: TSQLLoader;
begin
  LLoader := TSQLLoader.Create('FB', TMemorySqlSource.Create.Add('FB', 'ORDER.FIND', 'SELECT 7'));
  try
    TAssert.AssertEquals('SELECT 7', LLoader['ORDER.FIND'].SQL);
  finally
    LLoader.Free;
  end;
end;

procedure TSqlLoaderSourceTests.Loader_DefaultSourceIsResource;
var
  LLoader: TSQLLoader;
begin
  LLoader := TSQLLoader.Create('TESTS');
  try
    TAssert.AssertTrue('Without a source, the loader must use resources', LLoader.Source is TResourceSqlSource);
    TAssert.AssertEquals('SELECT 1 FROM SAMPLE', LLoader['SAMPLE.FIND'].SQL);
  finally
    LLoader.Free;
  end;
end;

procedure TSqlLoaderSourceTests.Loader_NotFound_RaisesWithDescription;
var
  LText: string;
  LLoader: TSQLLoader;
  LMessage: string;
begin
  LLoader := TSQLLoader.Create('FB', TMemorySqlSource.Create);
  try
    LMessage := '';
    try
      LText := LLoader['NOPE'].SQL;
    except
      on E: ESQLLoaderException do
        LMessage := E.Message;
    end;
    TAssert.AssertTrue('A missing SQL must raise ESQLLoaderException', LMessage <> '');
    TAssert.AssertTrue('The message must say where it looked', Pos('memory FB/NOPE', LMessage) > 0);
  finally
    LLoader.Free;
  end;
end;

procedure TSqlLoaderSourceTests.Loader_CachesText;
var
  LText: string;
  LCounting: TCountingSqlSource;
  LSource: ISqlSource;
  LLoader: TSQLLoader;
begin
  LCounting := TCountingSqlSource.Create(TMemorySqlSource.Create.Add('FB', 'X', 'SELECT 8'));
  LSource := LCounting;
  LLoader := TSQLLoader.Create('FB', LSource);
  try
    LText := LLoader['X'].SQL;
    LText := LLoader['x'].SQL;
    TAssert.AssertEquals('The second load (any case) must come from the cache', 1, LCounting.Calls);
  finally
    LLoader.Free;
  end;
end;

procedure TSqlLoaderSourceTests.Loader_ClearCache_ReloadsFromSource;
var
  LText: string;
  LCounting: TCountingSqlSource;
  LSource: ISqlSource;
  LLoader: TSQLLoader;
begin
  LCounting := TCountingSqlSource.Create(TMemorySqlSource.Create.Add('FB', 'X', 'SELECT 9'));
  LSource := LCounting;
  LLoader := TSQLLoader.Create('FB', LSource);
  try
    LText := LLoader['X'].SQL;
    LLoader.ClearCache;
    LText := LLoader['X'].SQL;
    TAssert.AssertEquals('After ClearCache the source must be asked again', 2, LCounting.Calls);
  finally
    LLoader.Free;
  end;
end;

initialization
  Randomize;
  TDUnitX.RegisterTestFixture(TSqlSourcesTests);
  TDUnitX.RegisterTestFixture(TSqlLoaderSourceTests);

end.
