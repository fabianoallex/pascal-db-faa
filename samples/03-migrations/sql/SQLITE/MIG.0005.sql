-- A separate DML migration: on Firebird, the column added by MIG.0004 can't be
-- used in the transaction that added it.
UPDATE SAMPLE_PRODUCTS SET ACTIVE = 1;
UPDATE SAMPLE_PRODUCTS SET ACTIVE = 0 WHERE ID = 3;
