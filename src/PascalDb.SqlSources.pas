unit PascalDb.SqlSources;

{$I pascaldb.inc}

{ Where SQL text comes from. TSQLLoader (PascalDb.SqlLoader) asks an
  ISqlSource for the text of <Directory>/<Name> and only then processes the
  template; the source decides how that text is stored:

  - TResourceSqlSource — RCDATA resources embedded in the executable, named
    SQL_<DIRECTORY>_<NAME> (dots in the name become underscores). The default.
    tools/build_sql_res.py builds the .res from a sql/<DIRECTORY>/*.sql tree
    on any OS: compiling a .rc on Linux FPC would need a MinGW C toolchain.
  - TDirectorySqlSource — .sql files read at runtime from
    <Root>/<Directory>/<Name>.sql. A relative root is resolved against the
    executable's folder, never the working directory (a Windows service runs
    with System32 as its working directory).
  - TMemorySqlSource — SQL registered in code; meant for tests.
  - TCompositeSqlSource — asks several sources in order; the first hit wins
    (e.g. a directory for local overrides, then the embedded resources).

  Files and resources are read as bytes and decoded as UTF-8 by
  PdbUtf8BytesToString (on pascal-common-faa's PcTryUtf8BytesToString since
  0.12.1). On FPC, `string` is an AnsiString in the process's
  default code page; unless that code page is UTF-8, characters outside it
  silently become "?". So when the SQL has non-ASCII characters and the code
  page isn't UTF-8, decoding raises ESqlSourceException instead of corrupting
  the SQL. LCL applications already run in UTF-8; console/service
  applications call SetMultiByteConversionCodePage(CP_UTF8) at startup. }

interface

uses
  Classes,
  SysUtils,
  SyncObjs,
  Generics.Collections;

type
  ESqlSourceException = class(Exception);

  /// Module handle accepted by FindResource on each compiler.
  TPdbModuleHandle = {$IFDEF FPC}TFPResourceHMODULE{$ELSE}HMODULE{$ENDIF};

  ISqlSource = interface
    ['{8E2C6B1A-4F3D-4A57-9C21-6D0B5E7F3A19}']
    /// Returns True and the SQL text if this source has <ADirectory>/<AName>.
    function TryGetSql(const ADirectory, AName: string; out ASql: string): Boolean;
    /// Where this source looked for <ADirectory>/<AName> — used in "not
    /// found" messages.
    function Describe(const ADirectory, AName: string): string;
  end;

  { TResourceSqlSource }

  TResourceSqlSource = class(TInterfacedObject, ISqlSource)
  private
    FInstance: TPdbModuleHandle;
  public
    /// AInstance = 0 uses the main module (HInstance).
    constructor Create(AInstance: TPdbModuleHandle = 0);
    class function ResourceName(const ADirectory, AName: string): string; static;
    function TryGetSql(const ADirectory, AName: string; out ASql: string): Boolean;
    function Describe(const ADirectory, AName: string): string;
  end;

  { TDirectorySqlSource }

  TDirectorySqlSource = class(TInterfacedObject, ISqlSource)
  private
    FRoot: string;
    function Candidates(const ADirectory, AName: string): TArray<string>;
  public
    /// ARoot: absolute, or relative to the executable's folder.
    constructor Create(const ARoot: string);
    function TryGetSql(const ADirectory, AName: string; out ASql: string): Boolean;
    function Describe(const ADirectory, AName: string): string;
    property Root: string read FRoot;
  end;

  { TMemorySqlSource }

  TMemorySqlSource = class(TInterfacedObject, ISqlSource)
  private
    FItems: TDictionary<string, string>;
    FLock: TCriticalSection;
    class function Key(const ADirectory, AName: string): string; static;
  public
    constructor Create;
    destructor Destroy; override;
    function Add(const ADirectory, AName, ASql: string): TMemorySqlSource;
    function TryGetSql(const ADirectory, AName: string; out ASql: string): Boolean;
    function Describe(const ADirectory, AName: string): string;
  end;

  { TCompositeSqlSource }

  TCompositeSqlSource = class(TInterfacedObject, ISqlSource)
  private
    FSources: TArray<ISqlSource>;
  public
    constructor Create(const ASources: array of ISqlSource);
    function TryGetSql(const ADirectory, AName: string; out ASql: string): Boolean;
    function Describe(const ADirectory, AName: string): string;
  end;

/// Decodes UTF-8 bytes (a leading BOM is skipped) into a string. On FPC it
/// raises ESqlSourceException when the bytes contain non-ASCII characters and
/// the process's default code page isn't UTF-8 (see the unit header).
/// AOrigin names the SQL in the error message. Public so third-party sources
/// can reuse it.
function PdbUtf8BytesToString(const ABytes: TBytes; const AOrigin: string): string;

implementation

uses
  {$IFNDEF FPC}
  Winapi.Windows,
  {$ENDIF}
  PascalCommon.Utf8;

const
  // RT_RCDATA comes from Winapi.Windows in Delphi; in FPC 3.2.2 it is only in
  // the system unit on non-Windows targets (on Windows it lives in the
  // Windows unit). MAKEINTRESOURCE(10) is the same value on every platform.
  SQL_RESOURCE_TYPE = {$IFDEF FPC}PChar(10){$ELSE}RT_RCDATA{$ENDIF};

function IsAbsolutePath(const APath: string): Boolean;
begin
  Result := (APath <> '') and
    ((ExtractFileDrive(APath) <> '') or (APath[1] = '/') or (APath[1] = PathDelim));
end;

function PdbUtf8BytesToString(const ABytes: TBytes; const AOrigin: string): string;
begin
  // The decoding is pascal-common-faa's (1.4.0); this keeps the exception and
  // the message this library always raised.
  if not PcTryUtf8BytesToString(ABytes, Result) then
    raise ESqlSourceException.CreateFmt(
      'SQL %s contains non-ASCII characters, but the process default code page is %d, ' +
      'not UTF-8 (65001): FPC would silently turn characters outside that code page into "?". ' +
      'Call SetMultiByteConversionCodePage(CP_UTF8) at startup (LCL applications already run in UTF-8).',
      [AOrigin, DefaultSystemCodePage]);
end;

function ReadFileBytes(const APath: string): TBytes;
var
  LStream: TFileStream;
begin
  LStream := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  try
    Result := nil;
    SetLength(Result, LStream.Size);
    if LStream.Size > 0 then
      LStream.ReadBuffer(Result[0], LStream.Size);
  finally
    LStream.Free;
  end;
end;

{ TResourceSqlSource }

constructor TResourceSqlSource.Create(AInstance: TPdbModuleHandle);
begin
  inherited Create;
  if AInstance = 0 then
    FInstance := HInstance
  else
    FInstance := AInstance;
end;

class function TResourceSqlSource.ResourceName(const ADirectory, AName: string): string;
begin
  Result := UpperCase('SQL_' + ADirectory + '_' + StringReplace(AName, '.', '_', [rfReplaceAll]));
end;

function TResourceSqlSource.TryGetSql(const ADirectory, AName: string; out ASql: string): Boolean;
var
  LName: string;
  LStream: TResourceStream;
  LBytes: TBytes;
begin
  LName := ResourceName(ADirectory, AName);
  Result := FindResource(FInstance, PChar(LName), SQL_RESOURCE_TYPE) <> 0;
  if not Result then
    Exit;
  LStream := TResourceStream.Create(FInstance, LName, SQL_RESOURCE_TYPE);
  try
    SetLength(LBytes, LStream.Size);
    if LStream.Size > 0 then
      LStream.ReadBuffer(LBytes[0], LStream.Size);
  finally
    LStream.Free;
  end;
  ASql := PdbUtf8BytesToString(LBytes, 'resource ' + LName);
end;

function TResourceSqlSource.Describe(const ADirectory, AName: string): string;
begin
  Result := 'resource ' + ResourceName(ADirectory, AName);
end;

{ TDirectorySqlSource }

constructor TDirectorySqlSource.Create(const ARoot: string);
var
  LRoot: string;
begin
  inherited Create;
  LRoot := ARoot;
  if not IsAbsolutePath(LRoot) then
    LRoot := ExtractFilePath(ParamStr(0)) + LRoot;
  FRoot := IncludeTrailingPathDelimiter(ExpandFileName(LRoot));
end;

function TDirectorySqlSource.Candidates(const ADirectory, AName: string): TArray<string>;
var
  LFile: string;
begin
  LFile := AName + '.sql';
  if ADirectory = '' then
    Result := TArray<string>.Create(FRoot + LFile)
  else if ADirectory = LowerCase(ADirectory) then
    Result := TArray<string>.Create(FRoot + ADirectory + PathDelim + LFile)
  else
    // File systems on Linux are case-sensitive: a 'FB' directory also
    // matches a lower-case 'fb' folder (the common on-disk convention).
    Result := TArray<string>.Create(
      FRoot + ADirectory + PathDelim + LFile,
      FRoot + LowerCase(ADirectory) + PathDelim + LFile);
end;

function TDirectorySqlSource.TryGetSql(const ADirectory, AName: string; out ASql: string): Boolean;
var
  LPath: string;
begin
  for LPath in Candidates(ADirectory, AName) do
    if FileExists(LPath) then
    begin
      ASql := PdbUtf8BytesToString(ReadFileBytes(LPath), 'file ' + LPath);
      Exit(True);
    end;
  Result := False;
end;

function TDirectorySqlSource.Describe(const ADirectory, AName: string): string;
var
  LPath: string;
begin
  Result := '';
  for LPath in Candidates(ADirectory, AName) do
  begin
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + 'file ' + LPath;
  end;
end;

{ TMemorySqlSource }

constructor TMemorySqlSource.Create;
begin
  inherited Create;
  FItems := TDictionary<string, string>.Create;
  FLock := TCriticalSection.Create;
end;

destructor TMemorySqlSource.Destroy;
begin
  FItems.Free;
  FLock.Free;
  inherited;
end;

class function TMemorySqlSource.Key(const ADirectory, AName: string): string;
begin
  Result := UpperCase(ADirectory) + '/' + UpperCase(AName);
end;

function TMemorySqlSource.Add(const ADirectory, AName, ASql: string): TMemorySqlSource;
begin
  FLock.Enter;
  try
    FItems.AddOrSetValue(Key(ADirectory, AName), ASql);
  finally
    FLock.Leave;
  end;
  Result := Self;
end;

function TMemorySqlSource.TryGetSql(const ADirectory, AName: string; out ASql: string): Boolean;
begin
  FLock.Enter;
  try
    Result := FItems.TryGetValue(Key(ADirectory, AName), ASql);
  finally
    FLock.Leave;
  end;
end;

function TMemorySqlSource.Describe(const ADirectory, AName: string): string;
begin
  Result := 'memory ' + Key(ADirectory, AName);
end;

{ TCompositeSqlSource }

constructor TCompositeSqlSource.Create(const ASources: array of ISqlSource);
var
  I: Integer;
begin
  inherited Create;
  SetLength(FSources, Length(ASources));
  for I := 0 to High(ASources) do
    FSources[I] := ASources[I];
end;

function TCompositeSqlSource.TryGetSql(const ADirectory, AName: string; out ASql: string): Boolean;
var
  LSource: ISqlSource;
begin
  for LSource in FSources do
    if LSource.TryGetSql(ADirectory, AName, ASql) then
      Exit(True);
  Result := False;
end;

function TCompositeSqlSource.Describe(const ADirectory, AName: string): string;
var
  LSource: ISqlSource;
begin
  Result := '';
  for LSource in FSources do
  begin
    if Result <> '' then
      Result := Result + '; ';
    Result := Result + LSource.Describe(ADirectory, AName);
  end;
end;

end.
