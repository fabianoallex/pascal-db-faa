unit PascalDb.Version;

{$I pascaldb.inc}

{ The library's version, as constants a consumer can test at compile time.

  A consumer that needs something added in a given version states it, so an
  older copy of pascal-db-faa fails the build with a clear message instead of
  a missing identifier somewhere inside the consumer:

    (*$IF PASCALDB_VERSION < 1100*)
      (*$MESSAGE FATAL 'my-app needs pascal-db-faa 0.11.0 or later'*)
    (*$IFEND*)

  (braces instead of the parenthesized form in real code), with
  PascalDb.Version in that unit's uses: a constant is only seen by the units
  that use the unit declaring it. Same format as PASCALCOMMON_VERSION
  (pascal-common-faa).

  Bump every constant here with each release, together with the version in
  the packages/*.lpk files, README.md and CHANGELOG.md. }

interface

const
  PASCALDB_VERSION_MAJOR = 0;
  PASCALDB_VERSION_MINOR = 11;
  PASCALDB_VERSION_PATCH = 0;

  /// major * 10000 + minor * 100 + patch: 0.11.0 is 1100, 1.2.3 is 10203.
  PASCALDB_VERSION = 1100;

  PASCALDB_VERSION_STRING = '0.11.0';

implementation

end.
