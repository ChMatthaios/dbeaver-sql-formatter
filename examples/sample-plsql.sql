/*
 * Oracle PL/SQL stored-object formatter stress test.
 * For DBeaver, select one complete program unit at a time before Ctrl+Shift+F.
 */

-- 01. Anonymous block
declare v_customer_id number:=1001;v_total number(18,2);v_segment varchar2(20);begin select nvl(sum(o.total_amount),0) into v_total from orders o where o.customer_id=v_customer_id and o.status_code='PAID';if v_total>=25000 then v_segment:='PLATINUM';elsif v_total>=10000 then v_segment:='GOLD';else v_segment:='STANDARD';end if;update customer set segment_code=v_segment,updated_at=systimestamp where customer_id=v_customer_id;exception when no_data_found then null;when others then raise;end;
/

-- 02. Procedure
create or replace procedure refresh_customer_summary(p_batch_id in number) as begin merge into customer_summary t using(select o.customer_id,count(*) as order_count,sum(o.total_amount) as total_amount,max(o.order_date) as last_order_date from orders o where o.status_code in('PAID','SHIPPED') group by o.customer_id) s on(t.customer_id=s.customer_id) when matched then update set t.order_count=s.order_count,t.total_amount=s.total_amount,t.last_order_date=s.last_order_date,t.updated_at=systimestamp when not matched then insert(customer_id,order_count,total_amount,last_order_date,batch_id) values(s.customer_id,s.order_count,s.total_amount,s.last_order_date,p_batch_id);commit;exception when others then rollback;raise;end;
/

-- 03. Function
create or replace function customer_segment(p_total_amount in number,p_order_count in number) return varchar2 is begin return case when p_total_amount>=25000 and p_order_count>=3 then 'PLATINUM' when p_total_amount>=10000 then 'GOLD' when p_total_amount>=5000 then 'SILVER' else 'STANDARD' end;end;
/

-- 04. Trigger
create or replace trigger trg_customer_status_audit after update of status_code on customer for each row begin if nvl(:old.status_code,'~')<>nvl(:new.status_code,'~') then insert into customer_status_audit(customer_id,old_status_code,new_status_code,changed_at) values(:new.customer_id,:old.status_code,:new.status_code,systimestamp);end if;end;
/

-- 05. Package specification
create or replace package customer_api as procedure refresh_summary(p_batch_id in number);function get_segment(p_customer_id in number) return varchar2;end customer_api;
/

-- 06. Package body
create or replace package body customer_api as procedure refresh_summary(p_batch_id in number) is begin update customer_summary set updated_at=systimestamp,batch_id=p_batch_id where customer_id in(select c.customer_id from customer c where c.active_flag='Y');end;function get_segment(p_customer_id in number) return varchar2 is v_total number(18,2);v_count number;begin select nvl(sum(o.total_amount),0),count(*) into v_total,v_count from orders o where o.customer_id=p_customer_id and o.status_code='PAID';return customer_segment(v_total,v_count);end;end customer_api;
/
