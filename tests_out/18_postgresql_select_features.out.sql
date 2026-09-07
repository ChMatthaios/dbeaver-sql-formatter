SELECT DISTINCT ON (c.id) c.id,
       c.payload->>'name' AS name,
       c.score::numeric(10, 2) AS score
  FROM customer c
 WHERE c.name ILIKE '%mat%'
 ORDER BY c.id, c.updated_at DESC
 LIMIT 20
 OFFSET 5
 FOR UPDATE SKIP LOCKED;
