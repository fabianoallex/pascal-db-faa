-- Firebird has no full-text search (docs/fulltext.md). The same table,
-- searched with LIKE and a pattern from PdbLikeContains. The text columns
-- are declared UTF8 for a database whose default character set is NONE.
-- Statements end with a caret line, so the file runs as a migration with
-- that terminator.
CREATE TABLE ARTICLES (
  ID    INTEGER NOT NULL PRIMARY KEY,
  TITLE VARCHAR(200) CHARACTER SET UTF8 NOT NULL,
  BODY  VARCHAR(4000) CHARACTER SET UTF8 NOT NULL
)
^
