/*
 * Oracle SQL formatter stress test.
 * Intentionally compact input covering Oracle-specific SQL syntax.
 */

-- 01. Hierarchical query
select e.employee_id,e.manager_id,e.employee_name,level as hierarchy_level,sys_connect_by_path(e.employee_name,' / ') as hierarchy_path from employee e start with e.manager_id is null connect by prior e.employee_id=e.manager_id order siblings by e.employee_name;

-- 02. Analytic functions + NVL + DECODE + ROWNUM
select * from(select c.customer_id,c.customer_name,nvl(sum(o.total_amount),0) as total_amount,row_number() over(partition by c.country_code order by nvl(sum(o.total_amount),0) desc,c.customer_id) as country_rank,decode(c.status_code,'A','ACTIVE','S','SUSPENDED','OTHER') as status_name from customer c left join orders o on o.customer_id=c.customer_id group by c.customer_id,c.customer_name,c.country_code,c.status_code order by total_amount desc) where rownum<=50;

-- 03. INSERT ALL
insert all when total_amount>=25000 then into vip_customer(customer_id,total_amount,tier_code) values(customer_id,total_amount,'PLATINUM') when total_amount>=10000 then into vip_customer(customer_id,total_amount,tier_code) values(customer_id,total_amount,'GOLD') else into standard_customer(customer_id,total_amount) values(customer_id,total_amount) select o.customer_id,sum(o.total_amount) as total_amount from orders o where o.status_code='PAID' group by o.customer_id;

-- 04. MERGE
merge into customer_summary t using(select o.customer_id,count(*) as order_count,sum(o.total_amount) as total_amount,max(o.order_date) as last_order_date from orders o where o.status_code in('PAID','SHIPPED') group by o.customer_id) s on(t.customer_id=s.customer_id) when matched then update set t.order_count=s.order_count,t.total_amount=s.total_amount,t.last_order_date=s.last_order_date,t.updated_at=systimestamp when not matched then insert(customer_id,order_count,total_amount,last_order_date,created_at) values(s.customer_id,s.order_count,s.total_amount,s.last_order_date,systimestamp);

-- 05. RETURNING INTO style DML
update customer set status_code='REVIEW',updated_at=systimestamp where customer_id=:customer_id returning customer_name,status_code into :customer_name,:status_code;

-- 06. CREATE VIEW
create or replace view reporting_customer_overview as select c.customer_id,c.customer_name,c.country_code,count(o.order_id) as order_count,nvl(sum(o.total_amount),0) as total_amount,max(o.order_date) as last_order_date from customer c left join orders o on o.customer_id=c.customer_id where c.active_flag='Y' group by c.customer_id,c.customer_name,c.country_code;

-- 07. Oracle q-quoted literal
select q'[Customer's status: "REVIEW"]' as message,current_date as run_date from dual;
