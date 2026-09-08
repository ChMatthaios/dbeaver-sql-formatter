CREATE OR REPLACE FUNCTION test_fn(p_id integer)
RETURNS integer
LANGUAGE plpgsql
AS $$
BEGIN
  -- keep this body exactly
  RETURN p_id + 1;
END;
$$;
