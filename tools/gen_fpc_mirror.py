"""Gera o espelho FPCUnit (tests/Unit/fpc/X.pas) a partir do teste DUnitX
(tests/Unit/X.pas).

Por que gerar em vez de manter os dois a mao: os corpos dos testes sao
escritos no dialeto de asserts do FPCUnit (TAssert.AssertEquals/AssertTrue...)
nos dois lados — no Delphi via PascalDb.DUnitXCompat. Com isso, a unica
diferenca real entre as duas suites e' a declaracao das fixtures e o
registro. Este script faz so' essa troca; o corpo sai byte a byte igual, e
"esqueci de portar o teste novo para o outro lado" deixa de ser possivel.

O mestre e' SEMPRE o arquivo DUnitX. Nunca edite tests/Unit/fpc/*.pas a mao:
edite o DUnitX e rode de novo.

Transformacoes, so' dentro de classes marcadas com [TestFixture]:
  [TestFixture] TX = class        -> TX = class(TTestCase)
  [Test] procedure Foo;           -> published: procedure Foo;
  [Setup] procedure Setup;        -> protected: procedure SetUp; override;
  [TearDown] procedure TearDown;  -> protected: procedure TearDown; override;
  demais membros public           -> continuam public (no FPCUnit, TODO
                                     metodo published vira teste)
Fora das fixtures:
  uses DUnitX.TestFramework, PascalDb.DUnitXCompat -> fpcunit, testregistry
  TDUnitX.RegisterTestFixture(TX)                  -> RegisterTest(TX)

Uso: python tools/gen_fpc_mirror.py            (todos os tests/Unit/*Tests.pas)
     python tools/gen_fpc_mirror.py --check    (falha se algum espelho estiver
                                                desatualizado; nao escreve)
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC_DIR = ROOT / 'tests' / 'Unit'
DST_DIR = SRC_DIR / 'fpc'

GENERATED_NOTE = (
    '{ ARQUIVO GERADO por tools/gen_fpc_mirror.py a partir de\n'
    '  tests/Unit/{name}.pas (DUnitX). Não edite à mão: edite o mestre DUnitX\n'
    '  e rode o script de novo. }\n\n'
)

SECTION_RE = re.compile(r'^\s*(private|protected|public|published|strict private|strict protected)\s*$')


class MirrorError(Exception):
    pass


def convert_fixture(lines):
    """lines: linhas do corpo da classe (entre 'TX = class' e 'end;')."""
    sections = {'private': [], 'protected': [], 'public': [], 'published': []}
    current = 'public'  # default de visibilidade de classe sem secao
    pending_attr = None
    trivia = []  # comentarios/linhas vazias: acompanham o proximo membro

    def emit(section, text):
        sections[section].extend(trivia)
        trivia.clear()
        sections[section].append(text)

    for line in lines:
        m = SECTION_RE.match(line)
        if m:
            current = m.group(1).replace('strict ', '')
            if current == 'published':
                raise MirrorError('fixture DUnitX com secao published: use public + [Test]')
            continue
        stripped = line.strip()
        if not pending_attr and (not stripped or stripped.startswith(('{', '//', '(*'))):
            trivia.append(line)
            continue
        attr = re.match(r'^\[(Test|Setup|TearDown)\]\s*(.*)$', stripped)
        if attr:
            kind, rest = attr.group(1), attr.group(2)
            if not rest:
                pending_attr = kind
                continue
            stripped, pending_attr = rest, kind
        if pending_attr:
            indent = '    '
            if pending_attr == 'Test':
                emit('published', indent + stripped)
            elif pending_attr == 'Setup':
                if not re.match(r'procedure\s+Setup\s*;', stripped, re.I):
                    raise MirrorError(f'[Setup] precisa se chamar SetUp no FPCUnit: {stripped}')
                emit('protected', indent + 'procedure SetUp; override;')
            else:
                if not re.match(r'procedure\s+TearDown\s*;', stripped, re.I):
                    raise MirrorError(f'[TearDown] precisa se chamar TearDown no FPCUnit: {stripped}')
                emit('protected', indent + 'procedure TearDown; override;')
            pending_attr = None
            continue
        emit(current, line)
    sections[current].extend(trivia)
    out = []
    for name in ('private', 'protected', 'public', 'published'):
        body = [l for l in sections[name]]
        if any(l.strip() for l in body):
            out.append(f'  {name}')
            out.extend(body)
    return out


def convert(text, name):
    lines = text.split('\n')
    out = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.strip() == '[TestFixture]':
            i += 1
            decl = lines[i]
            m = re.match(r'^(\s*)(\w+)\s*=\s*class\s*$', decl)
            if not m:
                raise MirrorError(f'{name}: fixture com heranca/interfaces nao suportada: {decl.strip()}')
            out.append(f'{m.group(1)}{m.group(2)} = class(TTestCase)')
            i += 1
            body = []
            while lines[i].strip() != 'end;':
                body.append(lines[i])
                i += 1
            out.extend(convert_fixture(body))
            out.append(lines[i])  # end;
            i += 1
            continue
        out.append(line)
        i += 1
    text = '\n'.join(out)

    # uses: troca o framework
    text, n = re.subn(r'\bDUnitX\.TestFramework,\s*\n\s*PascalDb\.DUnitXCompat,', 'fpcunit, testregistry,', text, count=1)
    if n != 1:
        raise MirrorError(f'{name}: uses sem "DUnitX.TestFramework, PascalDb.DUnitXCompat," em sequencia')
    text = re.sub(r'TDUnitX\.RegisterTestFixture\((\w+)\);', r'RegisterTest(\1);', text)
    # Qualquer uso de API DUnitX que sobrou (Assert.AreEqual, TDUnitX...) nao
    # existe no FPCUnit: o mestre tem que usar so' o dialeto TAssert.*.
    leftover = re.search(r'\b(TDUnitX|Assert\.[A-Z]\w*)\b', text)
    if leftover:
        raise MirrorError(f'{name}: API DUnitX no corpo ({leftover.group(0)}); use TAssert.*')

    # Logo apos "unit X;": modo do FPC e o aviso de arquivo gerado. O
    # cabecalho do mestre vem em seguida, intacto.
    note = GENERATED_NOTE.replace('{name}', name)
    text, n = re.subn(r'^(unit [\w.]+;\n\n)',
                      lambda m: m.group(1) + '{$mode delphi}{$H+}\n\n' + note,
                      text, count=1, flags=re.M)
    if n != 1:
        raise MirrorError(f'{name}: "unit X;" seguido de linha em branco nao encontrado')
    return text


def main():
    check = '--check' in sys.argv
    DST_DIR.mkdir(parents=True, exist_ok=True)
    stale = []
    for src in sorted(SRC_DIR.glob('*Tests.pas')):
        text = src.read_text(encoding='utf-8-sig')
        mirror = convert(text, src.stem)
        dst = DST_DIR / src.name
        current = dst.read_text(encoding='utf-8-sig') if dst.exists() else None
        if current != mirror:
            stale.append(dst.name)
            if not check:
                dst.write_text(mirror, encoding='utf-8-sig', newline='\n')
    if check and stale:
        print('Espelhos FPCUnit desatualizados:', ', '.join(stale))
        print('Rode: python tools/gen_fpc_mirror.py')
        sys.exit(1)
    print(('Desatualizados: ' if check else 'Gerados/atualizados: ') + (', '.join(stale) or 'nenhum'))


if __name__ == '__main__':
    main()
