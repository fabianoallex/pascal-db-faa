unit PascalDb.Registry;

{$I pascaldb.inc}

{ Registro global de fábricas por nome (TDBRegistry): permite que o ponto de
  montagem da aplicação registre uma ou mais IDBFactory (ex.: uma por banco)
  e que o resto do código as recupere pelo nome, sem depender do adapter
  concreto. GetFactory devolve nil para nome não registrado. }

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
