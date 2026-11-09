-- Full-text search on PostgreSQL (docs/fulltext.md), measured on 17.
-- A text search configuration that drops accents before stemming, so agua
-- finds the row with the accented word and cafes finds cafe. It needs the
-- unaccent extension (trusted since PostgreSQL 13, so a database owner can
-- create it). unaccent itself cannot go into the generated column, it is
-- not immutable, but a configuration that uses it can.
-- Statements end with a caret line, so the file runs as a migration with
-- that terminator.
CREATE EXTENSION IF NOT EXISTS unaccent
^
CREATE TEXT SEARCH CONFIGURATION pt_unaccent (COPY = portuguese)
^
ALTER TEXT SEARCH CONFIGURATION pt_unaccent
  ALTER MAPPING FOR hword, hword_part, word WITH unaccent, portuguese_stem
^
CREATE TABLE ARTICLES (
  ID         INTEGER NOT NULL PRIMARY KEY,
  TITLE      VARCHAR(200) NOT NULL,
  BODY       VARCHAR(4000) NOT NULL,
  SEARCH_DOC TSVECTOR GENERATED ALWAYS AS (to_tsvector('pt_unaccent', TITLE || ' ' || BODY)) STORED
)
^
CREATE INDEX IX_ARTICLES_SEARCH ON ARTICLES USING GIN (SEARCH_DOC)
^
