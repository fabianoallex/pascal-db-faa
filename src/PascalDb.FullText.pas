unit PascalDb.FullText;

{$I pascaldb.inc}

{ Full-text search values: what a user typed turned into the value of the
  parameter a database's native full-text search reads (PostgreSQL
  to_tsquery, MySQL/MariaDB MATCH ... AGAINST in boolean mode, SQLite FTS5
  MATCH), so that no input can make the query fail or change its meaning.

  The library writes no full-text SQL: the index, the column and the query
  are the application's (reference SQL in docs/fulltext/sql, guide in
  docs/fulltext.md), because the shape of the query differs between
  databases, a predicate on the table on PostgreSQL and MySQL, a join with
  the FTS5 table on SQLite. What the library owns is the value: raw user
  text in those syntaxes fails (measured: FTS5 refused 13 of 28 inputs such
  as a lone quote, "-word", "50%" or "d'agua"; MySQL refused "word)", "*"
  and "+"; to_tsquery anything with a space) or quietly means something
  else ("-word" excludes, "OR" joins). So the text is cut into words
  (PdbFullTextWords: letters and digits; ASCII punctuation, Unicode spaces
  and punctuation, symbols and emoji separate them) and the dialect writes
  each word in a form its syntax reads literally, joined by its own
  operators: quoted lexemes for to_tsquery, +word for MySQL, quoted strings
  for FTS5.

  The options choose all words or any word, and a prefix match on the last
  word (search as you type); the default is all words, no prefix. MySQL and
  MariaDB never index words shorter than innodb_ft_min_token_size or in the
  stopword list, and in boolean mode a required word the index doesn't hold
  matches no row at all ("+pao +de +queijo" finds nothing, measured): in
  all-words mode their dialect drops those words (MySQLMinTokenSize and
  MySQLStopwords: InnoDB's defaults, to be changed when the server's
  settings are). PostgreSQL drops its stopwords by itself.

  A dialect offers this through IFullTextDialect, a separate interface like
  IPagingDialect, so a dialect registered by an application still compiles.
  Firebird has no full-text search and SQL Server's (a separate component,
  filled in the background) isn't covered: PdbSupportsFullText says False
  and the application searches with LIKE (PdbLikeContains). The mock's
  dialect writes PostgreSQL's form. }

interface

uses
  SysUtils,
  PascalDb.Interfaces;

type
  TFullTextMatch = (
    ftmAllWords,  // every word must appear
    ftmAnyWord    // at least one word; order the rows by the score
  );

  TFullTextOptions = record
    Match: TFullTextMatch;
    // The last word also matches the words it starts ("pol" finds
    // "polvilho").
    PrefixLastWord: Boolean;
    // MySQL/MariaDB, all-words mode only: words shorter than this (in
    // characters) or in MySQLStopwords are left out, since the index never
    // holds them; the last word is kept when PrefixLastWord is set. The
    // server's innodb_ft_min_token_size and stopword table (InnoDB's
    // defaults below; MyISAM tables use ft_min_word_len and their own list).
    MySQLMinTokenSize: Integer;
    MySQLStopwords: TArray<string>;
    // All words, no prefix, InnoDB's minimum (3) and default stopwords.
    // Start from it: a record declared without it has no stopwords and no
    // minimum.
    class function Default: TFullTextOptions; static;
  end;

  // A separate interface, like IPagingDialect, so a dialect registered by an
  // application before it existed still compiles.
  IFullTextDialect = interface
    ['{5B0E7C2A-9D41-4F3B-8E6A-1C2D3F4A5B6C}']
    // The parameter value for AWords (at least one, each made of letters and
    // digits only, from PdbFullTextWords). '' when the dialect leaves every
    // word out.
    function GetFullTextQuery(const AWords: TArray<string>; const AOptions: TFullTextOptions): string;
  end;

const
  // InnoDB's default stopword list (INFORMATION_SCHEMA.INNODB_FT_DEFAULT_STOPWORD,
  // the same on MySQL 8.4 and MariaDB 11.4).
  PDB_INNODB_STOPWORDS: array[0..34] of string = ('a', 'about', 'an', 'are', 'as', 'at', 'be',
    'by', 'com', 'de', 'en', 'for', 'from', 'how', 'i', 'in', 'is', 'it', 'la', 'of', 'on',
    'or', 'that', 'the', 'this', 'to', 'und', 'was', 'what', 'when', 'where', 'who', 'will',
    'with', 'www');
  PDB_INNODB_MIN_TOKEN_SIZE = 3;

/// The words of AText: runs of letters and digits. ASCII punctuation and
/// spaces, the underscore, Latin-1 punctuation, Unicode spaces and general
/// punctuation, symbols, arrows, emoji and invalid characters separate
/// words. On FPC the text is UTF-8 (see CLAUDE.md, runtime requirements).
function PdbFullTextWords(const AText: string): TArray<string>;

/// Characters (Unicode code points) in AWord.
function PdbCodePointCount(const AWord: string): Integer;

/// Whether ADialect (or the dialect of the scope's connection) implements
/// IFullTextDialect. False: search with LIKE (PdbLikeContains) instead.
function PdbSupportsFullText(const ADialect: ISQLDialect): Boolean; overload;
function PdbSupportsFullText(const AScope: IScopeTransaction): Boolean; overload;

/// The full-text parameter value for AText on ADialect (or on the dialect
/// of the scope's connection). '' when AText has no word the database can
/// search for: don't run the query, there is nothing to find. Raises
/// EArgumentException when the dialect doesn't implement IFullTextDialect.
function PdbFullTextQuery(const ADialect: ISQLDialect; const AText: string;
  const AOptions: TFullTextOptions): string; overload;
function PdbFullTextQuery(const ADialect: ISQLDialect; const AText: string): string; overload;
function PdbFullTextQuery(const AScope: IScopeTransaction; const AText: string;
  const AOptions: TFullTextOptions): string; overload;
function PdbFullTextQuery(const AScope: IScopeTransaction; const AText: string): string; overload;

/// Each syntax, for the built-in dialects and for an application's own:
/// PostgreSQL to_tsquery ('w1' & 'w2':*), MySQL/MariaDB boolean mode
/// (+w1 +w2*), SQLite FTS5 ("w1" "w2"*). AWords as GetFullTextQuery gets them.
function PdbFullTextPostgreSQL(const AWords: TArray<string>; const AOptions: TFullTextOptions): string;
function PdbFullTextMySQL(const AWords: TArray<string>; const AOptions: TFullTextOptions): string;
function PdbFullTextSQLite(const AWords: TArray<string>; const AOptions: TFullTextOptions): string;

implementation

uses
  PascalDb.Paging;

{ TFullTextOptions }

class function TFullTextOptions.Default: TFullTextOptions;
var
  I: Integer;
begin
  Result.Match := ftmAllWords;
  Result.PrefixLastWord := False;
  Result.MySQLMinTokenSize := PDB_INNODB_MIN_TOKEN_SIZE;
  SetLength(Result.MySQLStopwords, Length(PDB_INNODB_STOPWORDS));
  for I := 0 to High(PDB_INNODB_STOPWORDS) do
    Result.MySQLStopwords[I] := PDB_INNODB_STOPWORDS[I];
end;

{ Words }

// The code point at AText[AIndex] and its length in string elements; 0 for
// an invalid sequence (a stray UTF-8 byte, a lone surrogate), with ALen 1.
function CodePointAt(const AText: string; AIndex: Integer; out ALen: Integer): Cardinal;
var
  C: Cardinal;
  {$IFNDEF UNICODE}
  LNeed, I: Integer;
  {$ENDIF}
begin
  ALen := 1;
  C := Ord(AText[AIndex]);
  {$IFDEF UNICODE}
  // UTF-16
  if (C >= $D800) and (C <= $DBFF) then
  begin
    if (AIndex < Length(AText)) and (Ord(AText[AIndex + 1]) >= $DC00) and (Ord(AText[AIndex + 1]) <= $DFFF) then
    begin
      ALen := 2;
      Exit($10000 + ((C - $D800) shl 10) + (Cardinal(Ord(AText[AIndex + 1])) - $DC00));
    end;
    Exit(0);
  end;
  if (C >= $DC00) and (C <= $DFFF) then
    Exit(0);
  Result := C;
  {$ELSE}
  // UTF-8
  if C < $80 then
    Exit(C);
  if (C and $E0) = $C0 then
  begin
    LNeed := 1;
    C := C and $1F;
  end
  else if (C and $F0) = $E0 then
  begin
    LNeed := 2;
    C := C and $0F;
  end
  else if (C and $F8) = $F0 then
  begin
    LNeed := 3;
    C := C and $07;
  end
  else
    Exit(0);
  if AIndex + LNeed > Length(AText) then
    Exit(0);
  for I := 1 to LNeed do
  begin
    if (Ord(AText[AIndex + I]) and $C0) <> $80 then
      Exit(0);
    C := (C shl 6) or (Cardinal(Ord(AText[AIndex + I])) and $3F);
  end;
  // overlong forms and surrogates are invalid UTF-8
  if ((LNeed = 1) and (C < $80)) or ((LNeed = 2) and (C < $800)) or ((LNeed = 3) and (C < $10000)) or
     ((C >= $D800) and (C <= $DFFF)) or (C > $10FFFF) then
    Exit(0);
  ALen := LNeed + 1;
  Result := C;
  {$ENDIF}
end;

function IsWordCodePoint(C: Cardinal): Boolean;
begin
  if C < $80 then
    Exit(((C >= Ord('0')) and (C <= Ord('9'))) or ((C >= Ord('A')) and (C <= Ord('Z'))) or
      ((C >= Ord('a')) and (C <= Ord('z'))));
  case C of
    // C1 controls and Latin-1 punctuation, keeping the ordinal indicators,
    // the superscript digits and the micro sign
    $80..$A9, $AB..$B1, $B4, $B6..$B8, $BB..$BF,
    $D7, $F7,                    // multiplication and division signs
    $2000..$206F,                // general punctuation, spaces, zero-width joiners
    $2100..$2BFF,                // letterlike symbols, arrows, math, technical, shapes, dingbats
    $3000..$3003,                // ideographic space and punctuation
    $E000..$F8FF,                // private use
    $FE00..$FE0F,                // variation selectors
    $FEFF,                       // byte order mark
    $FFF0..$FFFF,                // specials
    $1F000..$1FAFF:              // emoji and pictographs
      Result := False;
  else
    Result := C <> 0;
  end;
end;

function PdbFullTextWords(const AText: string): TArray<string>;
var
  I, LLen, LStart, LCount: Integer;
  LWord: Boolean;

  procedure AddWord(AEnd: Integer);
  begin
    if LStart > 0 then
    begin
      if LCount = Length(Result) then
        SetLength(Result, LCount * 2 + 4);
      Result[LCount] := Copy(AText, LStart, AEnd - LStart);
      Inc(LCount);
      LStart := 0;
    end;
  end;

begin
  SetLength(Result, 0);
  LCount := 0;
  LStart := 0;
  I := 1;
  while I <= Length(AText) do
  begin
    LWord := IsWordCodePoint(CodePointAt(AText, I, LLen));
    if LWord then
    begin
      if LStart = 0 then
        LStart := I;
    end
    else
      AddWord(I);
    Inc(I, LLen);
  end;
  AddWord(I);
  SetLength(Result, LCount);
end;

function PdbCodePointCount(const AWord: string): Integer;
var
  I, LLen: Integer;
begin
  Result := 0;
  I := 1;
  while I <= Length(AWord) do
  begin
    CodePointAt(AWord, I, LLen);
    Inc(Result);
    Inc(I, LLen);
  end;
end;

{ Syntaxes }

function JoinWords(const AWords: TArray<string>; const AOptions: TFullTextOptions;
  const AOpen, AClose, APrefix, AAllSep, AAnySep: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(AWords) do
  begin
    if I > 0 then
      if AOptions.Match = ftmAllWords then
        Result := Result + AAllSep
      else
        Result := Result + AAnySep;
    Result := Result + AOpen + AWords[I] + AClose;
    if AOptions.PrefixLastWord and (I = High(AWords)) then
      Result := Result + APrefix;
  end;
end;

function PdbFullTextPostgreSQL(const AWords: TArray<string>; const AOptions: TFullTextOptions): string;
begin
  // A quoted lexeme is read as text, so no word can be an operator; the
  // configuration's parser still splits and stems it, and drops stopwords.
  Result := JoinWords(AWords, AOptions, '''', '''', ':*', ' & ', ' | ');
end;

function PdbFullTextSQLite(const AWords: TArray<string>; const AOptions: TFullTextOptions): string;
begin
  // FTS5: a string in double quotes is a phrase, never an operator or a
  // column name; phrases side by side are ANDed.
  Result := JoinWords(AWords, AOptions, '"', '"', '*', ' ', ' OR ');
end;

function IsStopword(const AWord: string; const AStopwords: TArray<string>): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(AStopwords) do
    if AnsiSameText(AStopwords[I], AWord) then
      Exit(True);
  Result := False;
end;

function PdbFullTextMySQL(const AWords: TArray<string>; const AOptions: TFullTextOptions): string;
var
  I: Integer;
  LLast: Boolean;
begin
  Result := '';
  for I := 0 to High(AWords) do
  begin
    LLast := I = High(AWords);
    if (AOptions.Match = ftmAllWords) and not (LLast and AOptions.PrefixLastWord) and
       ((PdbCodePointCount(AWords[I]) < AOptions.MySQLMinTokenSize) or
        IsStopword(AWords[I], AOptions.MySQLStopwords)) then
      Continue;
    if Result <> '' then
      Result := Result + ' ';
    if AOptions.Match = ftmAllWords then
      Result := Result + '+';
    Result := Result + AWords[I];
    if LLast and AOptions.PrefixLastWord then
      Result := Result + '*';
  end;
end;

{ Entry points }

function PdbSupportsFullText(const ADialect: ISQLDialect): Boolean;
begin
  Result := Supports(ADialect, IFullTextDialect);
end;

function PdbSupportsFullText(const AScope: IScopeTransaction): Boolean;
begin
  Result := PdbSupportsFullText(PdbDialectOf(AScope));
end;

function PdbFullTextQuery(const ADialect: ISQLDialect; const AText: string;
  const AOptions: TFullTextOptions): string;
var
  LFullText: IFullTextDialect;
  LWords: TArray<string>;
begin
  if not Supports(ADialect, IFullTextDialect, LFullText) then
    raise EArgumentException.Create('PdbFullTextQuery: the SQL dialect does not implement ' +
      'IFullTextDialect (Firebird and SQL Server don''t). Check PdbSupportsFullText and search ' +
      'with LIKE (PdbLikeContains) where it says False.');
  LWords := PdbFullTextWords(AText);
  if Length(LWords) = 0 then
    Exit('');
  Result := LFullText.GetFullTextQuery(LWords, AOptions);
end;

function PdbFullTextQuery(const ADialect: ISQLDialect; const AText: string): string;
begin
  Result := PdbFullTextQuery(ADialect, AText, TFullTextOptions.Default);
end;

function PdbFullTextQuery(const AScope: IScopeTransaction; const AText: string;
  const AOptions: TFullTextOptions): string;
begin
  Result := PdbFullTextQuery(PdbDialectOf(AScope), AText, AOptions);
end;

function PdbFullTextQuery(const AScope: IScopeTransaction; const AText: string): string;
begin
  Result := PdbFullTextQuery(PdbDialectOf(AScope), AText, TFullTextOptions.Default);
end;

end.
