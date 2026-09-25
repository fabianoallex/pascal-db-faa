unit PascalDb.DUnitXCompat;

{ Adaptador fino: expõe a API de asserts do FPCUnit (TAssert.AssertEquals,
  AssertTrue, AssertFalse, Fail) por cima do Assert do DUnitX. Mesmo padrão do
  Redis.DUnitXCompat no pascal-redis-faa.

  Os testes são escritos UMA vez, no dialeto do FPCUnit, nos mestres DUnitX
  (tests/Unit/*Tests.pas); o espelho FPCUnit (tests/Unit/fpc) é gerado por
  tools/gen_fpc_mirror.py trocando só a declaração das fixtures. Este
  adaptador é o que deixa o mestre compilar no Delphi.

  O conjunto de overloads espelha o do TAssert do FPCUnit 3.2.2 — inclusive o
  que ele NÃO tem: não existe AssertEquals(Double, Double) sem delta. Um
  overload desses aqui deixaria o mestre compilar no Delphi comparando ponto
  flutuante de um jeito, enquanto no FPC a mesma linha cai no overload
  Currency (4 casas decimais) e compara de outro — foi assim que um teste de
  TDateTime passava no FPC com precisão de Currency. Ponto flutuante sempre
  com delta explícito (0 = exato).

  Comparação de texto é sempre sensível a maiúsculas, como a do FPCUnit:
  Assert.AreEqual(string, string) do DUnitX ignora maiúsculas POR PADRÃO. }

interface

uses
  DUnitX.TestFramework;

type
  TAssert = class
  public
    class procedure AssertEquals(const AExpected, AActual: string); overload;
    class procedure AssertEquals(const AMessage, AExpected, AActual: string); overload;
    class procedure AssertEquals(AExpected, AActual: Integer); overload;
    class procedure AssertEquals(const AMessage: string; AExpected, AActual: Integer); overload;
    class procedure AssertEquals(AExpected, AActual: Int64); overload;
    class procedure AssertEquals(const AMessage: string; AExpected, AActual: Int64); overload;
    class procedure AssertEquals(AExpected, AActual: Currency); overload;
    class procedure AssertEquals(const AMessage: string; AExpected, AActual: Currency); overload;
    class procedure AssertEquals(AExpected, AActual, ADelta: Double); overload;
    class procedure AssertEquals(const AMessage: string; AExpected, AActual, ADelta: Double); overload;
    class procedure AssertEquals(AExpected, AActual: Boolean); overload;
    class procedure AssertEquals(const AMessage: string; AExpected, AActual: Boolean); overload;

    class procedure AssertTrue(ACondition: Boolean); overload;
    class procedure AssertTrue(const AMessage: string; ACondition: Boolean); overload;
    class procedure AssertFalse(ACondition: Boolean); overload;
    class procedure AssertFalse(const AMessage: string; ACondition: Boolean); overload;

    class procedure Fail(const AMessage: string);
  end;

implementation

class procedure TAssert.AssertEquals(const AExpected, AActual: string);
begin
  // False = sensivel a maiusculas. O padrao do DUnitX seria True.
  Assert.AreEqual(AExpected, AActual, False);
end;

class procedure TAssert.AssertEquals(const AMessage, AExpected, AActual: string);
begin
  Assert.AreEqual(AExpected, AActual, False, AMessage);
end;

class procedure TAssert.AssertEquals(AExpected, AActual: Integer);
begin
  Assert.AreEqual(AExpected, AActual);
end;

class procedure TAssert.AssertEquals(const AMessage: string; AExpected, AActual: Integer);
begin
  Assert.AreEqual(AExpected, AActual, AMessage);
end;

class procedure TAssert.AssertEquals(AExpected, AActual: Int64);
begin
  Assert.AreEqual(AExpected, AActual);
end;

class procedure TAssert.AssertEquals(const AMessage: string; AExpected, AActual: Int64);
begin
  Assert.AreEqual(AExpected, AActual, AMessage);
end;

class procedure TAssert.AssertEquals(AExpected, AActual: Currency);
begin
  Assert.AreEqual(AExpected, AActual);
end;

class procedure TAssert.AssertEquals(const AMessage: string; AExpected, AActual: Currency);
begin
  Assert.AreEqual(AExpected, AActual, AMessage);
end;

class procedure TAssert.AssertEquals(AExpected, AActual, ADelta: Double);
begin
  Assert.AreEqual(AExpected, AActual, ADelta);
end;

class procedure TAssert.AssertEquals(const AMessage: string; AExpected, AActual, ADelta: Double);
begin
  Assert.AreEqual(AExpected, AActual, ADelta, AMessage);
end;

class procedure TAssert.AssertEquals(AExpected, AActual: Boolean);
begin
  Assert.AreEqual(AExpected, AActual);
end;

class procedure TAssert.AssertEquals(const AMessage: string; AExpected, AActual: Boolean);
begin
  Assert.AreEqual(AExpected, AActual, AMessage);
end;

class procedure TAssert.AssertTrue(ACondition: Boolean);
begin
  Assert.IsTrue(ACondition);
end;

class procedure TAssert.AssertTrue(const AMessage: string; ACondition: Boolean);
begin
  Assert.IsTrue(ACondition, AMessage);
end;

class procedure TAssert.AssertFalse(ACondition: Boolean);
begin
  Assert.IsFalse(ACondition);
end;

class procedure TAssert.AssertFalse(const AMessage: string; ACondition: Boolean);
begin
  Assert.IsFalse(ACondition, AMessage);
end;

class procedure TAssert.Fail(const AMessage: string);
begin
  Assert.Fail(AMessage);
end;

end.
