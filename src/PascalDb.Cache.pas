unit PascalDb.Cache;

{$I pascaldb.inc}

{ PdbInvalidateAfterCommit: invalidates tags of a cache (IPcCache, from
  pascal-common-faa's PascalCommon.Cache) after the transaction a scope
  belongs to commits.

  The cache itself belongs to the application, in the service or behind the
  repository's interface (docs/cache.md): a hit takes nothing from the pool.
  What a cache
  needs from this library is to invalidate after the commit, never before
  (the cache's decision C7), or a concurrent reader can load the old row and
  put it back; and a repository whose scope is nested in the caller's can't
  tell when the real commit happens. This is PdbAfterCommit
  (PascalDb.AfterCommit) with the invalidation written once, so the right way
  is also the short way.

  A nil cache does nothing, so a repository that runs with the cache turned
  off needs no "if". IPcCache.Invalidate never raises for a store that is
  down (the TTL bounds the staleness), so the action doesn't raise either in
  that case. The tags are copied when the action is added. }

interface

uses
  PascalDb.Interfaces,
  PascalCommon.Cache;

/// After the commit of the transaction AScope belongs to, ACache.Invalidate(ATags);
/// nothing if it rolls back (or AScope's own savepoint does). ACache = nil: nothing.
/// Raises EAfterCommitException (PascalDb.AfterCommit) when AScope isn't started.
procedure PdbInvalidateAfterCommit(const AScope: IScopeTransaction; const ACache: IPcCache;
  const ATags: array of string);

implementation

uses
  PascalDb.AfterCommit;

type
  TInvalidateAction = class(TInterfacedObject, IAfterCommitAction)
  private
    FCache: IPcCache;
    FTags: array of string;
  public
    constructor Create(const ACache: IPcCache; const ATags: array of string);
    procedure Run;
  end;

constructor TInvalidateAction.Create(const ACache: IPcCache; const ATags: array of string);
var
  I: Integer;
begin
  inherited Create;
  FCache := ACache;
  SetLength(FTags, Length(ATags));
  for I := 0 to High(ATags) do
    FTags[I] := ATags[I];
end;

procedure TInvalidateAction.Run;
begin
  FCache.Invalidate(FTags);
end;

procedure PdbInvalidateAfterCommit(const AScope: IScopeTransaction; const ACache: IPcCache;
  const ATags: array of string);
var
  LAction: IAfterCommitAction;
begin
  if (ACache = nil) or (Length(ATags) = 0) then
    Exit;
  LAction := TInvalidateAction.Create(ACache, ATags);
  PdbAfterCommitAction(AScope, LAction);
end;

end.
