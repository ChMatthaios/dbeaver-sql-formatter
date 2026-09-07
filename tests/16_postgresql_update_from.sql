update customer c set name = s.name, email = s.email from customer_stage s where c.id = s.id and s.batch_id = 42 returning c.id, c.name;
