-- SQL Server full-text search is a separate component, filled in the
-- background, and not covered by the library (docs/fulltext.md). The same
-- table, searched with LIKE and a pattern from PdbLikeContains. NVARCHAR
-- because a VARCHAR holds only the code page of its collation.
-- Statements end with a caret line, so the file runs as a migration with
-- that terminator.
CREATE TABLE ARTICLES (
  ID    INT NOT NULL PRIMARY KEY,
  TITLE NVARCHAR(200) NOT NULL,
  BODY  NVARCHAR(4000) NOT NULL
)
^
