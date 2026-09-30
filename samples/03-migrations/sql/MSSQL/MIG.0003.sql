-- Seed data (DML): applied in the same transaction as its version record.
-- N'...' literals: a plain '...' is converted to the database's code page.
INSERT INTO SAMPLE_PRODUCTS (ID, NAME, PRICE) VALUES (1, N'Café', 12.50);
INSERT INTO SAMPLE_PRODUCTS (ID, NAME, PRICE) VALUES (2, N'Pão de queijo', 8.90);
INSERT INTO SAMPLE_PRODUCTS (ID, NAME, PRICE) VALUES (3, N'Guaraná', 6.00);
