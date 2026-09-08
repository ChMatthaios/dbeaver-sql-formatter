/*
 * ANSI / common SQL formatter stress test.
 * These statements are intentionally compact/ugly so the formatter has real work to do.
 */

-- 01. CTE + window functions + joins + CASE + EXISTS
with customer_base as (select c.customer_id,c.customer_name,c.country_code,c.created_at from customer c where c.active_flag='Y'),order_totals as (select o.customer_id,count(*) as order_count,sum(o.total_amount) as total_amount,max(o.order_date) as last_order_date from orders o where o.order_date>=date '2025-01-01' group by o.customer_id) select cb.customer_id,cb.customer_name,coalesce(ot.order_count,0) as order_count,coalesce(ot.total_amount,0) as total_amount,row_number() over(partition by cb.country_code order by coalesce(ot.total_amount,0) desc,cb.customer_id) as country_rank,case when coalesce(ot.total_amount,0)>=25000 then 'PLATINUM' when coalesce(ot.total_amount,0)>=10000 then 'GOLD' else 'STANDARD' end as customer_segment from customer_base cb left join order_totals ot on ot.customer_id=cb.customer_id where not exists(select 1 from customer_blacklist b where b.customer_id=cb.customer_id and b.active_flag='Y') order by cb.country_code,coalesce(ot.total_amount,0) desc,cb.customer_id;

-- 02. INSERT with SELECT
insert into customer_snapshot(customer_id,customer_name,total_amount,snapshot_date) select c.customer_id,c.customer_name,coalesce(sum(o.total_amount),0),current_date from customer c left join orders o on o.customer_id=c.customer_id where c.active_flag='Y' group by c.customer_id,c.customer_name;

-- 03. UPDATE with correlated predicates and CASE
update customer_summary set customer_segment=case when total_amount>=25000 and order_count>=3 then 'PLATINUM' when total_amount>=10000 then 'GOLD' else 'STANDARD' end,review_required_flag=case when exists(select 1 from customer_blacklist b where b.customer_id=customer_summary.customer_id and b.active_flag='Y') then 1 when total_amount>=50000 and order_count<=2 then 1 else 0 end where customer_id in(select o.customer_id from orders o where o.order_date>=date '2025-01-01' group by o.customer_id having sum(o.total_amount)>=1000);

-- 04. DELETE with EXISTS / NOT EXISTS
delete from customer_stage s where s.load_batch_id=20260908 and (s.external_customer_id is null or trim(s.external_customer_id)='') and exists(select 1 from load_control lc where lc.load_batch_id=s.load_batch_id and lc.source_system=s.source_system) and not exists(select 1 from customer c where c.external_customer_id=s.external_customer_id);

-- 05. CREATE VIEW
create view active_customer_overview as select c.customer_id,c.customer_name,c.country_code,count(o.order_id) as order_count,coalesce(sum(o.total_amount),0) as total_amount from customer c left join orders o on o.customer_id=c.customer_id where c.active_flag='Y' group by c.customer_id,c.customer_name,c.country_code;
