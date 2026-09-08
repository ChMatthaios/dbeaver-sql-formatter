/*
 * PostgreSQL stored-object formatter stress test.
 * For DBeaver, select one complete object at a time before Ctrl+Shift+F.
 */

-- 01. VIEW
create or replace view reporting.customer_order_summary as select c.id as customer_id,c.name,count(o.id) as order_count,coalesce(sum(o.total_amount),0)::numeric(18,2) as total_amount,max(o.order_date) as last_order_date from customer c left join orders o on o.customer_id=c.id where c.active=true group by c.id,c.name;

-- 02. FUNCTION with dollar-quoted PL/pgSQL body
create or replace function reporting.customer_segment(p_customer_id bigint) returns text language plpgsql as $$
declare v_total numeric(18,2);v_count integer;
begin
select coalesce(sum(o.total_amount),0),count(*) into v_total,v_count from orders o where o.customer_id=p_customer_id and o.status='PAID';
if v_total>=25000 and v_count>=3 then return 'PLATINUM';elsif v_total>=10000 then return 'GOLD';else return 'STANDARD';end if;
end;
$$;

-- 03. PROCEDURE
create or replace procedure reporting.refresh_customer_summary(p_batch_id bigint) language plpgsql as $$
begin
insert into customer_summary(customer_id,total_amount,order_count,batch_id) select o.customer_id,sum(o.total_amount),count(*),p_batch_id from orders o where o.status='PAID' group by o.customer_id on conflict(customer_id) do update set total_amount=excluded.total_amount,order_count=excluded.order_count,batch_id=excluded.batch_id,updated_at=current_timestamp;
end;
$$;

-- 04. Trigger function
create or replace function reporting.audit_customer_status() returns trigger language plpgsql as $$
begin
if old.status_code is distinct from new.status_code then insert into customer_status_audit(customer_id,old_status_code,new_status_code,changed_at) values(new.id,old.status_code,new.status_code,current_timestamp);end if;return new;
end;
$$;

-- 05. Trigger
create trigger trg_customer_status_audit after update of status_code on customer for each row execute function reporting.audit_customer_status();
