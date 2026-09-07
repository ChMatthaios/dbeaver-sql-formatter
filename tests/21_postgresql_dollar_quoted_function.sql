create or replace function test_fn(p_id integer)
returns integer
language plpgsql
as $$
BEGIN
  -- keep this body exactly
  RETURN p_id + 1;
END;
$$;
