-- Full-text search on SQLite with FTS5 (docs/fulltext.md), measured on
-- 3.40 and 3.53. ARTICLES_FTS is an external content table, it indexes
-- the rows of ARTICLES without a second copy of the text, and the three
-- triggers keep it up to date. The tokenizer drops accents. FTS5 has no
-- stemming and no stopwords. The SQLite library must be built with FTS5
-- (the sqlite.org builds and Debian packages are).
-- Statements end with a caret line, because the triggers have semicolons
-- inside, so the file runs as a migration with that terminator.
CREATE TABLE ARTICLES (
  ID    INTEGER NOT NULL PRIMARY KEY,
  TITLE VARCHAR(200) NOT NULL,
  BODY  VARCHAR(4000) NOT NULL
)
^
CREATE VIRTUAL TABLE ARTICLES_FTS USING fts5(
  TITLE, BODY,
  content = 'ARTICLES', content_rowid = 'ID',
  tokenize = 'unicode61 remove_diacritics 2'
)
^
CREATE TRIGGER ARTICLES_FTS_AI AFTER INSERT ON ARTICLES BEGIN
  INSERT INTO ARTICLES_FTS (rowid, TITLE, BODY) VALUES (new.ID, new.TITLE, new.BODY);
END
^
CREATE TRIGGER ARTICLES_FTS_AD AFTER DELETE ON ARTICLES BEGIN
  INSERT INTO ARTICLES_FTS (ARTICLES_FTS, rowid, TITLE, BODY) VALUES ('delete', old.ID, old.TITLE, old.BODY);
END
^
CREATE TRIGGER ARTICLES_FTS_AU AFTER UPDATE ON ARTICLES BEGIN
  INSERT INTO ARTICLES_FTS (ARTICLES_FTS, rowid, TITLE, BODY) VALUES ('delete', old.ID, old.TITLE, old.BODY);
  INSERT INTO ARTICLES_FTS (rowid, TITLE, BODY) VALUES (new.ID, new.TITLE, new.BODY);
END
^
