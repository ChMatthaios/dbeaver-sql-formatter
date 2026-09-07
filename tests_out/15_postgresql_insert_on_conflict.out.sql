INSERT INTO customer ( id, name, email )
VALUES ( 1, 'Matt', 'm@example.com' )
ON CONFLICT (id)
DO UPDATE
   SET name = EXCLUDED.name,
       email = EXCLUDED.email
RETURNING id, name;
