program MockRepository;

{ Sample 01: exercising a repository against TMockDBFactory, with no database.

  TCityRepository (samples/common) only depends on IDBFactory. Here it gets
  the library's in-memory mock, which returns canned results by SQL key
  (AddResult) and records every execution with a snapshot of its parameters
  (LastExecution, ExecutionCount). That is enough to check the repository's
  own logic: validation and normalization before any SQL runs, the parameters
  it binds, and how it maps result rows to records.

  The checks are plain code (Check below) to show the mock doesn't depend on
  a test framework; in a real project they would live in DUnitX or FPCUnit
  tests. The program exits with code 1 if any check fails.

  Lifetime: TMockDBFactory is reference-counted (TInterfacedObject) and the
  repository keeps it in an IDBFactory field. Hold it in an interface
  variable too (LFactory below) and never call Free: a class variable alone
  would let the repository's reference free it early.

  Same source for Delphi (MockRepository.dproj) and Lazarus/FPC
  (MockRepository.lpi). }

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}
{$APPTYPE CONSOLE}

uses
  {$IFDEF UNIX}
  cthreads,
  cwstring, // FPC on Unix: needed for non-ASCII text in Variants (see CLAUDE.md)
  {$ENDIF}
  SysUtils,
  PascalDb.Interfaces,
  PascalDb.Mock,
  Samples.CityRepository;

var
  GFailures: Integer = 0;

procedure Check(ACondition: Boolean; const AWhat: string);
begin
  if ACondition then
    Writeln('  ok    ', AWhat)
  else
  begin
    Writeln('  FAIL  ', AWhat);
    Inc(GFailures);
  end;
end;

procedure InsertBindsNormalizedParams;
var
  LMock: TMockDBFactory;
  LFactory: IDBFactory;
  LRepo: TCityRepository;
  LExec: TMockExecution;
begin
  Writeln('Insert binds the normalized values');
  LMock := TMockDBFactory.Create;
  LFactory := LMock;
  LRepo := TCityRepository.Create(LFactory);
  try
    LRepo.Insert(City(' 3550308 ', 'São Paulo', 'sp'));

    LExec := LMock.LastExecution('CITY.INSERT');
    Check(Assigned(LExec), 'CITY.INSERT was executed');
    Check(not LExec.WasOpen, 'through ExecSql (no result set expected)');
    Check(LExec.AsString('CODE') = '3550308', 'CODE is trimmed');
    Check(LExec.AsString('NAME') = 'São Paulo', 'NAME keeps its non-ASCII text');
    Check(LExec.AsString('STATE') = 'SP', 'STATE is upper-cased');
  finally
    LRepo.Free;
  end;
end;

procedure InvalidCityNeverReachesTheDatabase;
var
  LMock: TMockDBFactory;
  LFactory: IDBFactory;
  LRepo: TCityRepository;
  LRaised: Boolean;
begin
  Writeln('An invalid city in a batch rejects the whole batch before any SQL runs');
  LMock := TMockDBFactory.Create;
  LFactory := LMock;
  LRepo := TCityRepository.Create(LFactory);
  try
    LRaised := False;
    try
      LRepo.InsertAll([City('3304557', 'Rio de Janeiro', 'RJ'), City('0000000', 'Nowhere', 'XYZ')]);
    except
      on ECityValidation do
        LRaised := True;
    end;
    Check(LRaised, 'ECityValidation is raised');
    Check(LMock.ExecutionCount('CITY.INSERT') = 0, 'no INSERT was executed, not even the valid one');
  finally
    LRepo.Free;
  end;
end;

procedure InsertAllRunsOneInsertPerCity;
var
  LMock: TMockDBFactory;
  LFactory: IDBFactory;
  LRepo: TCityRepository;
begin
  Writeln('InsertAll runs one INSERT per city');
  LMock := TMockDBFactory.Create;
  LFactory := LMock;
  LRepo := TCityRepository.Create(LFactory);
  try
    LRepo.InsertAll([City('3304557', 'Rio de Janeiro', 'RJ'), City('3509502', 'Campinas', 'SP')]);
    Check(LMock.ExecutionCount('CITY.INSERT') = 2, 'two executions recorded');
    Check(LMock.LastExecution('CITY.INSERT').AsString('NAME') = 'Campinas', 'the last one is Campinas');
  finally
    LRepo.Free;
  end;
end;

procedure FindByStateMapsRows;
var
  LMock: TMockDBFactory;
  LFactory: IDBFactory;
  LRepo: TCityRepository;
  LCities: TArray<TCity>;
begin
  Writeln('FindByState maps each row to a TCity');
  LMock := TMockDBFactory.Create;
  LFactory := LMock;
  // The canned result the "database" returns for this SQL key.
  LMock.AddResult('CITY.BY_STATE', TMockQueryResult.MultiRows(
    ['CODE', 'NAME', 'STATE'],
    [TArray<Variant>.Create('3509502', 'Campinas', 'SP'),
     TArray<Variant>.Create('3550308', 'São Paulo', 'SP')]));
  LRepo := TCityRepository.Create(LFactory);
  try
    LCities := LRepo.FindByState(' sp ');
    Check(LMock.LastExecution('CITY.BY_STATE').AsString('STATE') = 'SP', 'the filter is normalized too');
    Check(Length(LCities) = 2, 'two cities returned');
    Check((Length(LCities) = 2) and (LCities[1].Name = 'São Paulo'), 'row values are mapped in order');
  finally
    LRepo.Free;
  end;
end;

procedure MissingResultIsReported;
var
  LMock: TMockDBFactory;
  LFactory: IDBFactory;
  LRepo: TCityRepository;
  LMessage: string;
begin
  Writeln('A query with no canned result fails with a descriptive message');
  LMock := TMockDBFactory.Create;
  LFactory := LMock;
  LRepo := TCityRepository.Create(LFactory);
  try
    LMessage := '';
    try
      LRepo.Count;
    except
      on E: Exception do
        LMessage := E.Message;
    end;
    Check(Pos('AddResult(''CITY.COUNT''', LMessage) > 0, 'the message says which AddResult is missing');
  finally
    LRepo.Free;
  end;
end;

begin
  {$IFDEF FPC}
  // Plain FPC console programs don't run in UTF-8 by default; without this,
  // non-ASCII text becomes "?" (see CLAUDE.md). Delphi doesn't need it.
  SetMultiByteConversionCodePage(CP_UTF8);
  {$ELSE}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  try
    InsertBindsNormalizedParams;
    InvalidCityNeverReachesTheDatabase;
    InsertAllRunsOneInsertPerCity;
    FindByStateMapsRows;
    MissingResultIsReported;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      Inc(GFailures);
    end;
  end;
  Writeln;
  if GFailures = 0 then
    Writeln('All checks passed.')
  else
  begin
    Writeln(GFailures, ' check(s) failed.');
    ExitCode := 1;
  end;
end.
