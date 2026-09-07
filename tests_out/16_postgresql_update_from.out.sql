UPDATE customer c
   SET name = s.name,
       email = s.email
  FROM customer_stage s
 WHERE c.id = s.id
   AND s.batch_id = 42
RETURNING c.id, c.name;
