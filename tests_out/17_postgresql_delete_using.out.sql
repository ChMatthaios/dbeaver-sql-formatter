DELETE FROM customer c
 USING customer_blacklist b
 WHERE c.id = b.customer_id
   AND b.active = TRUE
RETURNING c.id;
