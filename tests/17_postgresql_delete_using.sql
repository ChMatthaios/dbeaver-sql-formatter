delete from customer c using customer_blacklist b where c.id = b.customer_id and b.active = true returning c.id;
