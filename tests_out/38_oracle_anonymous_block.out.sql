DECLARE
  v_customer_id NUMBER := 1001;
  v_name VARCHAR2(100);
BEGIN
  SELECT CUSTOMER_ID,
         CUSTOMER_NAME
    INTO v_customer_id, v_name
    FROM CUSTOMER
   WHERE CUSTOMER_ID = v_customer_id;
  DBMS_OUTPUT.PUT_LINE(q'[Customer: ]' || v_name);
EXCEPTION
  WHEN NO_DATA_FOUND THEN
    v_name := NULL;
END;
/
