/*
 * DB2 SQL PL stored-object formatter stress test.
 * For DBeaver, select one complete object at a time before Ctrl+Shift+F.
 * The @ terminator is shown only as a convenient test delimiter.
 */

-- 01. VIEW
create or replace view reporting.customer_order_summary as select c.customer_id,c.customer_name,c.country_code,count(o.order_id) as order_count,coalesce(sum(o.total_amount),0) as total_amount,max(o.order_date) as last_order_date from customer c left join orders o on o.customer_id=c.customer_id where c.active_flag='Y' group by c.customer_id,c.customer_name,c.country_code@

-- 02. SQL PL procedure
create or replace procedure reporting.refresh_customer_summary(in p_batch_id bigint) language sql begin atomic merge into reporting.customer_summary t using(select o.customer_id,count(*) as order_count,sum(o.total_amount) as total_amount,max(o.order_date) as last_order_date from orders o where o.status_code in('PAID','SHIPPED') group by o.customer_id) s on t.customer_id=s.customer_id when matched then update set order_count=s.order_count,total_amount=s.total_amount,last_order_date=s.last_order_date,updated_at=current timestamp when not matched then insert(customer_id,order_count,total_amount,last_order_date,batch_id) values(s.customer_id,s.order_count,s.total_amount,s.last_order_date,p_batch_id);end@

-- 03. SQL PL scalar function
create or replace function reporting.customer_segment(p_total_amount decimal(18,2),p_order_count bigint) returns varchar(20) language sql deterministic no external action return case when p_total_amount>=25000 and p_order_count>=3 then 'PLATINUM' when p_total_amount>=10000 then 'GOLD' when p_total_amount>=5000 then 'SILVER' else 'STANDARD' end@

-- 04. Trigger
create or replace trigger reporting.trg_customer_status_audit after update of status_code on customer referencing old as old_row new as new_row for each row when(old_row.status_code<>new_row.status_code) begin atomic insert into customer_status_audit(customer_id,old_status_code,new_status_code,changed_at) values(new_row.customer_id,old_row.status_code,new_row.status_code,current timestamp);end@
