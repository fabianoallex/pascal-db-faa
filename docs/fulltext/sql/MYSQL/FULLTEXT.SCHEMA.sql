-- Full-text search on MySQL and MariaDB (docs/fulltext.md), measured on
-- MySQL 8.4 and MariaDB 11.4. The database character set is utf8mb4 with
-- its default accent and case insensitive collation, which the index
-- follows. MATCH must name exactly the columns of a FULLTEXT index. The
-- index holds no word shorter than innodb_ft_min_token_size (3) and no
-- stopword, and it only sees committed rows.
-- Statements end with a caret line, so the file runs as a migration with
-- that terminator.
CREATE TABLE ARTICLES (
  ID    INT NOT NULL PRIMARY KEY,
  TITLE VARCHAR(200) NOT NULL,
  BODY  VARCHAR(4000) NOT NULL,
  FULLTEXT KEY FT_ARTICLES (TITLE, BODY)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
^
