unit PascalDb.AfterCommit;

{$I pascaldb.inc}

{ Actions that run after a transaction commits: PdbAfterCommit and
  PdbAfterCommitAction add one to the transaction an IScopeTransaction belongs
  to, and the real commit runs it, never a nested scope's savepoint release.

  Why: a repository that commits its own scope can't tell whether that commit
  is the real one. When the caller already had a transaction, the
  repository's scope is nested and its Commit only releases a savepoint, so
  anything written after it (a cache invalidation, waking a dispatcher,
  sending an e-mail) runs before the data is visible to other connections.
  The design, with the reasons for each decision, is
  docs/after-commit-design.md (A1 to A10).

  - The actions live on the transaction (IAfterCommitActions, implemented by
    TTransactionBase in PascalDb.Adapter.Base, so every adapter built on it
    has them), and every scope of a transaction shares it. They run in the
    order they were added, on the thread that commits, after InTransaction
    is False; the list is taken out before the first one runs.
  - A rollback drops them. A nested scope's rollback (to its savepoint)
    drops those added since that scope started (Truncate), so an action of
    work that was undone never runs. A failed commit drops them too.
  - An action that raises doesn't make the commit fail: the data is already
    committed. The next actions still run, and the failure goes to the
    transaction's OnFailure (the pool reports it as pekAfterCommitFailed).
    EExternal (an access violation and the like) propagates.
  - Adding an action when no transaction is running raises
    EAfterCommitException: running it at once would hide the bug this is
    for.

  Dual-compiler: TAfterCommitProc follows PASCALDB_FUNCREFS ("reference to"
  on Delphi, "of object" on FPC 3.2.2), and takes a string argument because
  a method can't capture the caller's local variables. Anything with more
  state is an IAfterCommitAction object. The actions are kept in a dynamic
  array rather than a generic list of interfaces. }

interface

uses
  SysUtils,
  PascalDb.Interfaces;

const
  PDB_AFTER_COMMIT_NO_TRANSACTION =
    'No transaction is running: start the scope before adding an action to run after its commit';

type
  EAfterCommitException = class(Exception);

  TAfterCommitProc = {$IFDEF PASCALDB_FUNCREFS}reference to procedure(const AArg: string)
    {$ELSE}procedure(const AArg: string) of object{$ENDIF};

  /// Told of an action that raised after the commit. An exception raised
  /// here is ignored.
  TAfterCommitFailureProc = {$IFDEF PASCALDB_FUNCREFS}reference to procedure(const AErrorClass, AErrorMessage: string)
    {$ELSE}procedure(const AErrorClass, AErrorMessage: string) of object{$ENDIF};

  IAfterCommitAction = interface
    ['{10E3F4F4-8983-4EBA-BACA-338C26AFD5E6}']
    procedure Run;
  end;

  /// What a transaction (or a scope that keeps its own list, as the mock's)
  /// implements. Used by one thread at a time, as the transaction itself.
  IAfterCommitActions = interface
    ['{8A9DC476-3E92-45B5-83F8-43170D12464D}']
    /// Raises EAfterCommitException when no transaction is running.
    procedure Add(const AAction: IAfterCommitAction);
    function Count: Integer;
    /// Drops the actions added after the first ACount.
    procedure Truncate(ACount: Integer);
    procedure SetOnFailure(const AOnFailure: TAfterCommitFailureProc);
  end;

  /// Named: Delphi doesn't assign one anonymous "array of" to another.
  TAfterCommitActionArray = array of IAfterCommitAction;

  /// The list behind IAfterCommitActions, for its implementers.
  TAfterCommitList = class
  private
    FItems: TAfterCommitActionArray;
    FCount: Integer;
    FOnFailure: TAfterCommitFailureProc;
  public
    procedure Add(const AAction: IAfterCommitAction);
    function Count: Integer;
    procedure Truncate(ACount: Integer);
    procedure Clear;
    /// Takes the actions out of the list, then runs each one (see the unit
    /// comment for what happens when one raises).
    procedure RunAll;
    property OnFailure: TAfterCommitFailureProc read FOnFailure write FOnFailure;
  end;

/// Runs AProc(AArg) after the transaction AScope belongs to commits; never if
/// it rolls back, or if AScope's own savepoint does.
procedure PdbAfterCommit(const AScope: IScopeTransaction; const AProc: TAfterCommitProc;
  const AArg: string = '');

/// The same with an object, for an action with more state than one string.
procedure PdbAfterCommitAction(const AScope: IScopeTransaction; const AAction: IAfterCommitAction);

/// The actions of the transaction AScope belongs to (the scope's own when it
/// keeps them). Raises EAfterCommitException when neither has them.
function PdbAfterCommitActionsOf(const AScope: IScopeTransaction): IAfterCommitActions;

implementation

type
  TProcAction = class(TInterfacedObject, IAfterCommitAction)
  private
    FProc: TAfterCommitProc;
    FArg: string;
  public
    constructor Create(const AProc: TAfterCommitProc; const AArg: string);
    procedure Run;
  end;

constructor TProcAction.Create(const AProc: TAfterCommitProc; const AArg: string);
begin
  inherited Create;
  FProc := AProc;
  FArg := AArg;
end;

procedure TProcAction.Run;
begin
  FProc(FArg);
end;

{ TAfterCommitList }

procedure TAfterCommitList.Add(const AAction: IAfterCommitAction);
begin
  if AAction = nil then
    raise EArgumentException.Create('An after-commit action can''t be nil');
  if FCount = Length(FItems) then
    SetLength(FItems, FCount * 2 + 4);
  FItems[FCount] := AAction;
  Inc(FCount);
end;

function TAfterCommitList.Count: Integer;
begin
  Result := FCount;
end;

procedure TAfterCommitList.Truncate(ACount: Integer);
var
  I: Integer;
begin
  if ACount < 0 then
    ACount := 0;
  for I := ACount to FCount - 1 do
    FItems[I] := nil;
  if ACount < FCount then
    FCount := ACount;
end;

procedure TAfterCommitList.Clear;
begin
  FItems := nil;
  FCount := 0;
end;

procedure TAfterCommitList.RunAll;
var
  LItems: TAfterCommitActionArray;
  LCount, I: Integer;
begin
  if FCount = 0 then
    Exit;
  // Taken out first: an action that commits again on the same transaction
  // object must not run this list a second time.
  LItems := FItems;
  LCount := FCount;
  FItems := nil;
  FCount := 0;
  for I := 0 to LCount - 1 do
    try
      LItems[I].Run;
    except
      on E: EExternal do
        raise;
      on E: Exception do
        if Assigned(FOnFailure) then
          try
            FOnFailure(E.ClassName, E.Message);
          except
            // A broken reporter must not undo a committed write.
          end;
    end;
end;

{ Functions }

function PdbAfterCommitActionsOf(const AScope: IScopeTransaction): IAfterCommitActions;
var
  LTransaction: ITransaction;
begin
  if AScope = nil then
    raise EArgumentException.Create('PdbAfterCommit needs a scope');
  if Supports(AScope, IAfterCommitActions, Result) then
    Exit;
  LTransaction := AScope.OriginalTransaction;
  if (LTransaction <> nil) and Supports(LTransaction, IAfterCommitActions, Result) then
    Exit;
  raise EAfterCommitException.Create('This scope''s transaction keeps no after-commit actions ' +
    '(IAfterCommitActions; an adapter''s transaction gets them from TTransactionBase)');
end;

procedure PdbAfterCommit(const AScope: IScopeTransaction; const AProc: TAfterCommitProc;
  const AArg: string);
var
  LActions: IAfterCommitActions;
  LAction: IAfterCommitAction;
begin
  if not Assigned(AProc) then
    raise EArgumentException.Create('An after-commit action can''t be nil');
  LActions := PdbAfterCommitActionsOf(AScope);
  // Held by a variable: a new object passed straight to a const interface
  // parameter is never released if Add raises.
  LAction := TProcAction.Create(AProc, AArg);
  LActions.Add(LAction);
end;

procedure PdbAfterCommitAction(const AScope: IScopeTransaction; const AAction: IAfterCommitAction);
begin
  PdbAfterCommitActionsOf(AScope).Add(AAction);
end;

end.
