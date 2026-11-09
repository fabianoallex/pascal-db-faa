unit PascalDb.FullTextTests;

{ Tests for the full-text values without a database (PascalDb.FullText): how
  user text is cut into words (ASCII and Unicode punctuation, emoji, accents),
  each built-in dialect's syntax for all words, any word and a prefix on the
  last word, MySQL/MariaDB leaving out the words its index never holds,
  input with every operator character in it, the dialects without full-text
  search (Firebird, SQL Server) and PdbFullTextQuery on a TMockDBFactory
  scope. The values running on each database are covered by the
  integration tests (PascalDb.FullTextTests in tests/Integration).

  DUnitX master, written in FPCUnit's assertion dialect (TAssert.*, through
  PascalDb.DUnitXCompat). The mirror in tests/Unit/fpc is generated from the
  master by tools/gen_fpc_mirror.py — edit only the master. }

interface

uses
  DUnitX.TestFramework,
  PascalDb.DUnitXCompat,
  SysUtils,
  PascalDb.Interfaces,
  PascalDb.SqlDialect,
  PascalDb.Mock,
  PascalDb.FullText;

type
  [TestFixture]
  TFullTextTests = class
  public
    [Test] procedure Words_SplitOnAsciiPunctuation;
    [Test] procedure Words_SplitOnUnicodePunctuationAndEmoji;
    [Test] procedure Words_NothingToSearch_EmptyValue;
    [Test] procedure CodePointCount_CountsCharacters;
    [Test] procedure Default_Options;
    [Test] procedure PostgreSQL_AllWords;
    [Test] procedure PostgreSQL_AnyWord_Prefix;
    [Test] procedure PostgreSQL_OperatorsAreNotPassedOn;
    [Test] procedure SQLite_AllWords_Prefix;
    [Test] procedure SQLite_AnyWord;
    [Test] procedure SQLite_OperatorsAreNotPassedOn;
    [Test] procedure MySQL_AllWords_LeavesOutShortWordsAndStopwords;
    [Test] procedure MySQL_AllWords_PrefixKeepsTheLastWord;
    [Test] procedure MySQL_AnyWord_KeepsEveryWord;
    [Test] procedure MySQL_OnlyWordsLeftOut_EmptyValue;
    [Test] procedure MySQL_StopwordsIgnoreCase;
    [Test] procedure MySQL_CustomSettings;
    [Test] procedure MariaDB_SameAsMySQL;
    [Test] procedure Output_OnlyWordsAndTheDialectsOperators;
    [Test] procedure FirebirdAndSqlServer_NoFullText_Raises;
    [Test] procedure MockScope_PostgreSQLForm;
  end;

implementation

function Dialect(const AName: string): ISQLDialect;
begin
  Result := TSQLDialectFactory.GetDialect(AName);
end;

function Options(AMatch: TFullTextMatch; APrefix: Boolean): TFullTextOptions;
begin
  Result := TFullTextOptions.Default;
  Result.Match := AMatch;
  Result.PrefixLastWord := APrefix;
end;

// A linear congruential step in 64 bits: the 32-bit product overflows, which
// Delphi's overflow checking (on in Debug) raises.
function NextSeed(ASeed: Cardinal): Cardinal;
begin
  Result := Cardinal((UInt64(ASeed) * 1103515245 + 12345) and $FFFFFFFF);
end;

function Joined(const AWords: TArray<string>): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(AWords) do
  begin
    if I > 0 then
      Result := Result + '|';
    Result := Result + AWords[I];
  end;
end;

{ TFullTextTests }

procedure TFullTextTests.Words_SplitOnAsciiPunctuation;
begin
  TAssert.AssertEquals('Café|com|leite|d|água|50|x|y',
    Joined(PdbFullTextWords('Café-com-leite, d''água! (50%) x_y')));
end;

procedure TFullTextTests.Words_SplitOnUnicodePunctuationAndEmoji;
begin
  // guillemets, em dash, ellipsis, curly quotes and an emoji separate words;
  // the ordinal indicator is part of one
  TAssert.AssertEquals('café|preto|leite|açúcar|nº5',
    Joined(PdbFullTextWords('«café»—preto… “leite” 😀açúcar nº5')));
end;

procedure TFullTextTests.Words_NothingToSearch_EmptyValue;
const
  INPUTS: array[0..3] of string = ('', '   ', '"*+()-:&|!<>~@''_', '😀 … —');
  DIALECTS: array[0..3] of string = ('PostgreSQL', 'MySQL', 'MariaDB', 'SQLite');
var
  LInput, LName: string;
begin
  for LInput in INPUTS do
  begin
    TAssert.AssertEquals('words of [' + LInput + ']', 0, Length(PdbFullTextWords(LInput)));
    for LName in DIALECTS do
      TAssert.AssertEquals(LName + ' [' + LInput + ']', '', PdbFullTextQuery(Dialect(LName), LInput));
  end;
end;

procedure TFullTextTests.CodePointCount_CountsCharacters;
begin
  TAssert.AssertEquals(2, PdbCodePointCount('pé'));
  TAssert.AssertEquals(3, PdbCodePointCount('açú'));
  TAssert.AssertEquals(1, PdbCodePointCount('😀'));
  TAssert.AssertEquals(0, PdbCodePointCount(''));
end;

procedure TFullTextTests.Default_Options;
var
  LOptions: TFullTextOptions;
begin
  LOptions := TFullTextOptions.Default;
  TAssert.AssertTrue('all words', LOptions.Match = ftmAllWords);
  TAssert.AssertFalse('no prefix', LOptions.PrefixLastWord);
  TAssert.AssertEquals(3, LOptions.MySQLMinTokenSize);
  TAssert.AssertEquals(35, Length(LOptions.MySQLStopwords));
end;

procedure TFullTextTests.PostgreSQL_AllWords;
begin
  TAssert.AssertEquals('''café'' & ''preto''', PdbFullTextQuery(Dialect('PostgreSQL'), 'café preto'));
end;

procedure TFullTextTests.PostgreSQL_AnyWord_Prefix;
begin
  TAssert.AssertEquals('''café'' | ''pre'':*',
    PdbFullTextQuery(Dialect('PostgreSQL'), 'café pre', Options(ftmAnyWord, True)));
  TAssert.AssertEquals('''café'' & ''pre'':*',
    PdbFullTextQuery(Dialect('PostgreSQL'), 'café pre', Options(ftmAllWords, True)));
end;

procedure TFullTextTests.PostgreSQL_OperatorsAreNotPassedOn;
begin
  TAssert.AssertEquals('''café'' & ''preto'' & ''x''',
    PdbFullTextQuery(Dialect('PostgreSQL'), 'café:* & !(preto) <-> ''x'''));
end;

procedure TFullTextTests.SQLite_AllWords_Prefix;
begin
  TAssert.AssertEquals('"café" "pol"*',
    PdbFullTextQuery(Dialect('SQLite'), 'café pol', Options(ftmAllWords, True)));
  TAssert.AssertEquals('"café" "pol"', PdbFullTextQuery(Dialect('SQLite'), 'café pol'));
end;

procedure TFullTextTests.SQLite_AnyWord;
begin
  TAssert.AssertEquals('"café" OR "preto"',
    PdbFullTextQuery(Dialect('SQLite'), 'café preto', Options(ftmAnyWord, False)));
end;

procedure TFullTextTests.SQLite_OperatorsAreNotPassedOn;
begin
  TAssert.AssertEquals('"NEAR" "café" "preto" "x"',
    PdbFullTextQuery(Dialect('SQLite'), 'NEAR(café "preto") -x'));
end;

procedure TFullTextTests.MySQL_AllWords_LeavesOutShortWordsAndStopwords;
begin
  // "de" is a stopword, "x" and "50" are shorter than 3 characters
  TAssert.AssertEquals('+pão +queijo', PdbFullTextQuery(Dialect('MySQL'), 'pão de queijo x 50'));
  // characters, not bytes: "pé" is 3 bytes in UTF-8
  TAssert.AssertEquals('+café', PdbFullTextQuery(Dialect('MySQL'), 'café pé'));
end;

procedure TFullTextTests.MySQL_AllWords_PrefixKeepsTheLastWord;
begin
  TAssert.AssertEquals('+café +de*',
    PdbFullTextQuery(Dialect('MySQL'), 'café de', Options(ftmAllWords, True)));
  TAssert.AssertEquals('+café +ca*',
    PdbFullTextQuery(Dialect('MySQL'), 'x café ca', Options(ftmAllWords, True)));
end;

procedure TFullTextTests.MySQL_AnyWord_KeepsEveryWord;
begin
  TAssert.AssertEquals('pão de queijo',
    PdbFullTextQuery(Dialect('MySQL'), 'pão de queijo', Options(ftmAnyWord, False)));
  TAssert.AssertEquals('pão de queijo*',
    PdbFullTextQuery(Dialect('MySQL'), 'pão de queijo', Options(ftmAnyWord, True)));
end;

procedure TFullTextTests.MySQL_OnlyWordsLeftOut_EmptyValue;
begin
  TAssert.AssertEquals('', PdbFullTextQuery(Dialect('MySQL'), 'de x'));
end;

procedure TFullTextTests.MySQL_StopwordsIgnoreCase;
begin
  TAssert.AssertEquals('+Café +Leite', PdbFullTextQuery(Dialect('MySQL'), 'Café DE Leite'));
end;

procedure TFullTextTests.MySQL_CustomSettings;
var
  LOptions: TFullTextOptions;
begin
  LOptions := TFullTextOptions.Default;
  LOptions.MySQLMinTokenSize := 2;
  LOptions.MySQLStopwords := TArray<string>.Create('queijo');
  TAssert.AssertEquals('+pão +de', PdbFullTextQuery(Dialect('MySQL'), 'pão de queijo x', LOptions));
  // no minimum, no stopwords: every word
  LOptions.MySQLMinTokenSize := 0;
  LOptions.MySQLStopwords := nil;
  TAssert.AssertEquals('+pão +de +queijo +x', PdbFullTextQuery(Dialect('MySQL'), 'pão de queijo x', LOptions));
end;

procedure TFullTextTests.MariaDB_SameAsMySQL;
begin
  TAssert.AssertEquals('+pão +queijo', PdbFullTextQuery(Dialect('MariaDB'), 'pão de queijo'));
end;

procedure TFullTextTests.Output_OnlyWordsAndTheDialectsOperators;
const
  DIALECTS: array[0..2] of string = ('PostgreSQL', 'MySQL', 'SQLite');
  // what each syntax may add around the words
  OPERATORS: array[0..2] of string = (' &|'':*', ' +*', ' "*');
var
  LSeed: Cardinal;
  I, J, K, D: Integer;
  LText, LValue, LWord: string;
  LWordChars: TSysCharSet;
  LOptions: TFullTextOptions;
begin
  LWordChars := ['0'..'9', 'A'..'Z', 'a'..'z'];
  LSeed := 12345;
  for I := 1 to 300 do
  begin
    // printable ASCII, operator characters included, deterministic
    LText := '';
    for J := 1 to Integer(LSeed mod 21) do
    begin
      LSeed := NextSeed(LSeed);
      LText := LText + Chr(32 + (LSeed shr 16) mod 95);
    end;
    LSeed := NextSeed(LSeed);
    for D := 0 to High(DIALECTS) do
      for K := 0 to 3 do
      begin
        LOptions := Options(TFullTextMatch(K div 2), Odd(K));
        LValue := PdbFullTextQuery(Dialect(DIALECTS[D]), LText, LOptions);
        for J := 1 to Length(LValue) do
          if not CharInSet(LValue[J], LWordChars) and (Pos(LValue[J], OPERATORS[D]) = 0) then
            TAssert.Fail(Format('%s [%s] -> [%s]: "%s" is neither a word character nor an operator',
              [DIALECTS[D], LText, LValue, LValue[J]]));
        // every word of the text is still a whole word in the value (MySQL
        // may leave some out)
        if DIALECTS[D] <> 'MySQL' then
          for LWord in PdbFullTextWords(LText) do
            TAssert.AssertTrue(Format('%s [%s] -> [%s] lost "%s"', [DIALECTS[D], LText, LValue, LWord]),
              Pos(LWord, LValue) > 0);
      end;
  end;
end;

procedure TFullTextTests.FirebirdAndSqlServer_NoFullText_Raises;
const
  NAMES: array[0..2] of string = ('Firebird', 'SQLServer', 'MSSQL');
var
  LName: string;
begin
  TAssert.AssertTrue(PdbSupportsFullText(Dialect('PostgreSQL')));
  TAssert.AssertTrue(PdbSupportsFullText(Dialect('MySQL')));
  TAssert.AssertTrue(PdbSupportsFullText(Dialect('SQLite')));
  for LName in NAMES do
  begin
    TAssert.AssertFalse(LName, PdbSupportsFullText(Dialect(LName)));
    try
      PdbFullTextQuery(Dialect(LName), 'café');
      TAssert.Fail(LName + ' must raise');
    except
      on E: EArgumentException do
        TAssert.AssertTrue('The message must point at PdbSupportsFullText: ' + E.Message,
          Pos('PdbSupportsFullText', E.Message) > 0);
    end;
  end;
end;

procedure TFullTextTests.MockScope_PostgreSQLForm;
var
  LFactory: IDBFactory;
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  LFactory := TMockDBFactory.Create;
  LScope := LFactory.GetPool.AcquireQuery(LQuery);
  TAssert.AssertTrue(PdbSupportsFullText(LScope));
  TAssert.AssertEquals('''café'' & ''preto''', PdbFullTextQuery(LScope, 'café, preto!'));
  TAssert.AssertEquals('''café'' | ''pre'':*', PdbFullTextQuery(LScope, 'café pre', Options(ftmAnyWord, True)));
end;

initialization
  TDUnitX.RegisterTestFixture(TFullTextTests);

end.
