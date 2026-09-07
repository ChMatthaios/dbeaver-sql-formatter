create temporary table temp_active as select id, name from customer where active = true;
