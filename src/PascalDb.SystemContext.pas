unit PascalDb.SystemContext;

{$I pascaldb.inc}

{ Replaceable clock (TClock) and wait (TSleep). Library code calls TClock.Now
  and TSleep.Sleep instead of SysUtils.Now/Sleep, and tests swap the
  implementation with SetClock/SetSleep (and restore the default with Reset)
  — that is what makes the pool's timeout, idle and wait behavior testable
  without a real clock or Sleep. }

interface

uses
  Classes, SysUtils;

type
  IClock = interface
    ['{BFE15358-5393-4F0C-A8CD-DF4B937B6B01}']
    function Now: TDateTime;
    function Date: TDateTime;
  end;

  { TSystemClock }

  TSystemClock = class(TInterfacedObject, IClock)
  public
    function Now: TDateTime;
    function Date: TDateTime;
  end;

  { TClockProvider }

  TClock = class
  private
    class var FClock: IClock;
  public
    class function Now: TDateTime; inline;
    class function Date: TDateTime; inline;
    class procedure SetClock(AClock: IClock);
    class procedure Reset;
  end;

  ISleep = interface
    ['{F1D9CB02-C791-48B6-AD4A-A0701A240764}']
    procedure Sleep(milliseconds: Cardinal);
  end;

  { TSystemSleep }

  TSystemSleep = class(TInterfacedObject, ISleep)
  public
    procedure Sleep(milliseconds: Cardinal);
  end;

  { TSleepProvider }

  TSleep = class
  private
    class var FSleep: ISleep;
  public
    class procedure Sleep(milliseconds: Cardinal); inline;
    class procedure SetSleep(ASleep: ISleep);
    class procedure Reset;
  end;

implementation

{ TSystemClock }

function TSystemClock.Now: TDateTime;
begin
  Result := SysUtils.Now;
end;

function TSystemClock.Date: TDateTime;
begin
  Result := SysUtils.Date;
end;

{ TClock }

class function TClock.Now: TDateTime;
begin
  if not Assigned(FClock) then
    FClock := TSystemClock.Create;
  Result := FClock.Now;
end;

class function TClock.Date: TDateTime;
begin
  if not Assigned(FClock) then
    FClock := TSystemClock.Create;
  Result := FClock.Date;
end;

class procedure TClock.SetClock(AClock: IClock);
begin
  FClock := AClock;
end;

class procedure TClock.Reset;
begin
  FClock := nil;
end;

{ TSystemSleep }

procedure TSystemSleep.Sleep(milliseconds: Cardinal);
begin
  SysUtils.Sleep(milliseconds);
end;

{ TSleep }

class procedure TSleep.Sleep(milliseconds: Cardinal);
begin
  if not Assigned(FSleep) then
    FSleep := TSystemSleep.Create;
  FSleep.Sleep(milliseconds);
end;

class procedure TSleep.SetSleep(ASleep: ISleep);
begin
  FSleep := ASleep;
end;

class procedure TSleep.Reset;
begin
  FSleep := nil;
end;

end.

