unit PascalDb.Registry;

{$I pascaldb.inc}

{ Global registry of factories by name (TDBRegistry): lets the application's
  composition root register one or more IDBFactory instances (e.g. one per
  database) and the rest of the code look them up by name, without depending
  on the concrete adapter. GetFactory returns nil for an unregistered name. }

interface

uses
  Classes,
  SysUtils,
  Generics.Collections,
  PascalDb.Interfaces;

type

  { TDBRegistry }

  TDBRegistry = class
  private
    class var FFactories: TDictionary<string, IDBFactory>;
  public
    class constructor Create;
    class destructor Destroy;
    class procedure RegisterFactory(const AFactoryName: string; AFactory: IDBFactory);
    class function GetFactory(const AFactoryName: string): IDBFactory;
  end;

implementation

{ TDBRegistry }

class constructor TDBRegistry.Create;
begin
  FFactories := TDictionary<string, IDBFactory>.Create;
end;

class destructor TDBRegistry.Destroy;
begin
  FFactories.Clear;
  FFactories.Free;
end;

class procedure TDBRegistry.RegisterFactory(const AFactoryName: string; AFactory: IDBFactory);
begin
  FFactories.Add(AFactoryName, AFactory);
end;

class function TDBRegistry.GetFactory(const AFactoryName: string): IDBFactory;
begin
  if not FFactories.TryGetValue(AFactoryName, Result) then
    Result := nil;
end;

end.
