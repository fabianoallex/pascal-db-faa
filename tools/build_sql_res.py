"""Builds a Windows .res file with the SQL files of a tree, as RCDATA
resources that TResourceSqlSource (PascalDb.SqlSources) can find.

Layout expected under SQL_ROOT (one level of sub-folders = SQL directories):

    SQL_ROOT/
      FB/ORDER.FIND.sql      -> resource SQL_FB_ORDER_FIND
      PG/ORDER.FIND.sql      -> resource SQL_PG_ORDER_FIND

Resource name = 'SQL_' + DIRECTORY + '_' + NAME with dots replaced by
underscores, upper-cased — the same rule as TResourceSqlSource.ResourceName.
Two files that map to the same name (e.g. ORDER.FIND.sql and ORDER_FIND.sql)
are an error.

Why a script instead of brcc32/windres: the .res format is simple and
identical for both compilers, but compiling a .rc is not portable — Delphi
has brcc32, FPC on Windows calls the windres that ships with Lazarus, and FPC
on Linux would need a MinGW C toolchain just to preprocess the .rc. This
script writes the .res directly (byte-for-byte what windres produces for the
equivalent .rc) on any OS, and both compilers link it with {$R file.res}.

Usage:
    python tools/build_sql_res.py SQL_ROOT OUT.res            (write)
    python tools/build_sql_res.py SQL_ROOT OUT.res --check    (exit 1 if OUT.res
                                                               is missing or stale)
"""
import struct
import sys
from pathlib import Path

RT_RCDATA = 10
MEMORY_FLAGS = 0x1030   # MOVEABLE | PURE | DISCARDABLE — what windres/brcc32 emit
LANGUAGE = 0x0409       # en-US, what windres emits by default


def pad4(data):
    return data + b'\0' * (-len(data) % 4)


def resource_name(directory, name):
    return ('SQL_' + directory + '_' + name.replace('.', '_')).upper()


def res_entry(name, data):
    header = struct.pack('<HH', 0xFFFF, RT_RCDATA) + (name + '\0').encode('utf-16-le')
    header = pad4(header) + struct.pack('<IHHII', 0, MEMORY_FLAGS, LANGUAGE, 0, 0)
    return pad4(struct.pack('<II', len(data), 8 + len(header)) + header + data)


# A .res file starts with an empty 32-byte entry (the 32-bit .res signature).
RES_SIGNATURE = struct.pack('<IIHHHHIHHII', 0, 32, 0xFFFF, 0, 0xFFFF, 0, 0, 0, 0, 0, 0)


def collect(root):
    entries = {}
    errors = []
    for folder in sorted(p for p in root.iterdir() if p.is_dir()):
        for sql in sorted(folder.glob('*.sql')):
            name = resource_name(folder.name, sql.stem)
            if name in entries:
                errors.append(f'{name}: both {entries[name][0]} and {sql}')
                continue
            entries[name] = (sql, sql.read_bytes())
    stray = sorted(p.name for p in root.glob('*.sql'))
    if stray:
        errors.append('SQL files must be inside a directory folder, not directly in the root: '
                      + ', '.join(stray))
    return entries, errors


def build(root):
    entries, errors = collect(root)
    if errors:
        raise SystemExit('build_sql_res: ' + '\n  '.join(['errors:'] + errors))
    data = RES_SIGNATURE + b''.join(res_entry(n, entries[n][1]) for n in sorted(entries))
    return data, len(entries)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    check = '--check' in sys.argv
    if len(args) != 2:
        raise SystemExit(__doc__)
    root, out = Path(args[0]), Path(args[1])
    if not root.is_dir():
        raise SystemExit(f'build_sql_res: {root} is not a directory')
    data, count = build(root)
    current = out.read_bytes() if out.exists() else None
    if check:
        if current != data:
            print(f'{out} is {"missing" if current is None else "out of date"}; '
                  f'run: python tools/build_sql_res.py {root} {out}')
            sys.exit(1)
        print(f'{out} is up to date ({count} SQL resources)')
        return
    if current != data:
        out.write_bytes(data)
        print(f'{out}: written ({count} SQL resources)')
    else:
        print(f'{out}: unchanged ({count} SQL resources)')


if __name__ == '__main__':
    main()
