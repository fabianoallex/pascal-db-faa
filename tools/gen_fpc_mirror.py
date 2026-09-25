"""Generates the FPCUnit mirror (tests/Unit/fpc/X.pas) from the DUnitX test
(tests/Unit/X.pas).

Why generate instead of maintaining both by hand: the test bodies are
written in FPCUnit's assertion dialect (TAssert.AssertEquals/AssertTrue...)
on both sides — on Delphi through PascalDb.DUnitXCompat. That leaves the
fixture declarations and the registration as the only real difference
between the two suites. This script swaps just that; the body comes out
byte-for-byte identical, and "forgot to port the new test to the other side"
stops being possible.

The master is ALWAYS the DUnitX file. Never edit tests/Unit/fpc/*.pas by
hand: edit the DUnitX file and run this again.

Transformations, only inside classes marked with [TestFixture]:
  [TestFixture] TX = class        -> TX = class(TTestCase)
  [Test] procedure Foo;           -> published: procedure Foo;
  [Setup] procedure Setup;        -> protected: procedure SetUp; override;
  [TearDown] procedure TearDown;  -> protected: procedure TearDown; override;
  other public members            -> stay public (in FPCUnit, EVERY
                                     published method becomes a test)
Outside the fixtures:
  uses DUnitX.TestFramework, PascalDb.DUnitXCompat -> fpcunit, testregistry
  TDUnitX.RegisterTestFixture(TX)                  -> RegisterTest(TX)

Usage: python tools/gen_fpc_mirror.py          (every tests/{Unit,Integration}/*Tests.pas)
       python tools/gen_fpc_mirror.py --check  (fails if any mirror is out of
                                                date; writes nothing)
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# Each suite folder holds DUnitX masters; its fpc/ sub-folder gets the mirrors.
SUITE_DIRS = [ROOT / 'tests' / 'Unit', ROOT / 'tests' / 'Integration']

GENERATED_NOTE = (
    '{ GENERATED FILE — produced by tools/gen_fpc_mirror.py from\n'
    '  tests/Unit/{name}.pas (DUnitX). Do not edit by hand: edit the DUnitX\n'
    '  master and run the script again. }\n\n'
)

SECTION_RE = re.compile(r'^\s*(private|protected|public|published|strict private|strict protected)\s*$')


class MirrorError(Exception):
    pass


def convert_fixture(lines):
    """lines: the class body lines (between 'TX = class' and 'end;')."""
    sections = {'private': [], 'protected': [], 'public': [], 'published': []}
    current = 'public'  # default visibility of a class with no section
    pending_attr = None
    trivia = []  # comments/blank lines: they go with the next member

    def emit(section, text):
        sections[section].extend(trivia)
        trivia.clear()
        sections[section].append(text)

    for line in lines:
        m = SECTION_RE.match(line)
        if m:
            current = m.group(1).replace('strict ', '')
            if current == 'published':
                raise MirrorError('DUnitX fixture with a published section: use public + [Test]')
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
                    raise MirrorError(f'[Setup] must be named SetUp for FPCUnit: {stripped}')
                emit('protected', indent + 'procedure SetUp; override;')
            else:
                if not re.match(r'procedure\s+TearDown\s*;', stripped, re.I):
                    raise MirrorError(f'[TearDown] must be named TearDown for FPCUnit: {stripped}')
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
                raise MirrorError(f'{name}: fixture with inheritance/interfaces is not supported: {decl.strip()}')
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

    # uses: swap the framework
    text, n = re.subn(r'\bDUnitX\.TestFramework,\s*\n\s*PascalDb\.DUnitXCompat,', 'fpcunit, testregistry,', text, count=1)
    if n != 1:
        raise MirrorError(f'{name}: uses clause lacks "DUnitX.TestFramework, PascalDb.DUnitXCompat," in sequence')
    text = re.sub(r'TDUnitX\.RegisterTestFixture\((\w+)\);', r'RegisterTest(\1);', text)
    # Any DUnitX API left over (Assert.AreEqual, TDUnitX...) doesn't exist in
    # FPCUnit: the master must use only the TAssert.* dialect.
    leftover = re.search(r'\b(TDUnitX|Assert\.[A-Z]\w*)\b', text)
    if leftover:
        raise MirrorError(f'{name}: DUnitX API in the body ({leftover.group(0)}); use TAssert.*')

    # Right after "unit X;": the FPC mode and the generated-file note. The
    # master's header follows, untouched.
    note = GENERATED_NOTE.replace('{name}', name)
    text, n = re.subn(r'^(unit [\w.]+;\n\n)',
                      lambda m: m.group(1) + '{$mode delphi}{$H+}\n\n' + note,
                      text, count=1, flags=re.M)
    if n != 1:
        raise MirrorError(f'{name}: "unit X;" followed by a blank line not found')
    return text


def main():
    check = '--check' in sys.argv
    stale = []
    for src in sorted(p for d in SUITE_DIRS if d.is_dir() for p in d.glob('*Tests.pas')):
        dst_dir = src.parent / 'fpc'
        dst_dir.mkdir(parents=True, exist_ok=True)
        text = src.read_text(encoding='utf-8-sig')
        mirror = convert(text, src.stem)
        dst = dst_dir / src.name
        current = dst.read_text(encoding='utf-8-sig') if dst.exists() else None
        if current != mirror:
            stale.append(dst.name)
            if not check:
                dst.write_text(mirror, encoding='utf-8-sig', newline='\n')
    if check and stale:
        print('Out-of-date FPCUnit mirrors:', ', '.join(stale))
        print('Run: python tools/gen_fpc_mirror.py')
        sys.exit(1)
    print(('Out of date: ' if check else 'Generated/updated: ') + (', '.join(stale) or 'none'))


if __name__ == '__main__':
    main()
