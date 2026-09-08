CREATE TEMPORARY TABLE temp_active AS
SELECT id,
       name
  FROM customer
 WHERE active = TRUE;
