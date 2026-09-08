/*
 * PostgreSQL formatter stress test.
 * Intentionally compact input covering PostgreSQL-specific syntax.
 */

-- 01. DISTINCT ON + JSON + casts + FILTER + window function
select distinct on(c.id) c.id,c.payload->>'name' as name,(c.payload->>'score')::numeric(10,2) as score,count(o.id) filter(where o.status='PAID') over(partition by c.country_code) as paid_order_count from customer c left join orders o on o.customer_id=c.id where c.name ilike '%mat%' and c.tags @> array['vip']::text[] order by c.id,c.updated_at desc limit 50 offset 10;

-- 02. INSERT ... ON CONFLICT ... DO UPDATE ... RETURNING
insert into customer(id,name,email,payload) values(1,'Matt','m@example.com','{"tier":"gold","active":true}'::jsonb),(2,'Chris','c@example.com','{"tier":"silver","active":true}'::jsonb) on conflict(id) do update set name=excluded.name,email=excluded.email,payload=excluded.payload,updated_at=current_timestamp returning id,name,payload->>'tier' as tier;

-- 03. UPDATE ... FROM ... RETURNING
update customer c set name=s.name,email=s.email,payload=jsonb_set(coalesce(c.payload,'{}'::jsonb),'{source}','"stage"'::jsonb,true),updated_at=current_timestamp from customer_stage s where c.id=s.customer_id and s.batch_id=42 returning c.id,c.name,c.email;

-- 04. DELETE ... USING ... RETURNING
delete from customer c using customer_blacklist b where c.id=b.customer_id and b.active=true and not exists(select 1 from protected_customer p where p.customer_id=c.id) returning c.id,c.name;

-- 05. WITH RECURSIVE
with recursive org_tree(employee_id,manager_id,employee_name,depth,path) as(select e.employee_id,e.manager_id,e.employee_name,1,array[e.employee_id] from employee e where e.manager_id is null union all select e.employee_id,e.manager_id,e.employee_name,t.depth+1,t.path||e.employee_id from employee e join org_tree t on e.manager_id=t.employee_id where not e.employee_id=any(t.path)) select employee_id,manager_id,employee_name,depth,path from org_tree order by path;

-- 06. LATERAL + aggregate FILTER
select c.id,c.name,x.last_order_date,x.total_amount,x.paid_amount from customer c left join lateral(select max(o.order_date) as last_order_date,sum(o.total_amount) as total_amount,sum(o.total_amount) filter(where o.status='PAID') as paid_amount from orders o where o.customer_id=c.id) x on true where c.active=true order by x.total_amount desc nulls last,c.id;

-- 07. CREATE TEMP TABLE AS SELECT
create temporary table temp_active_customer as select c.id,c.name,c.country_code,current_timestamp as created_at from customer c where c.active=true and exists(select 1 from orders o where o.customer_id=c.id and o.order_date>=current_date-interval '90 days');

-- 08. Row locking
select q.id,q.customer_id,q.payload from processing_queue q where q.status='READY' order by q.created_at,q.id for update skip locked limit 25;
