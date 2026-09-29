-- utf8mb4 declared: a server's default character set varies (MySQL's utf8 has no
-- 4-byte characters).
CREATE TABLE SAMPLE_PRODUCTS (
  ID    INTEGER       NOT NULL,
  NAME  VARCHAR(100)  NOT NULL,
  PRICE NUMERIC(15,2) NOT NULL,
  CONSTRAINT PK_SAMPLE_PRODUCTS PRIMARY KEY (ID)
) DEFAULT CHARSET=utf8mb4;
