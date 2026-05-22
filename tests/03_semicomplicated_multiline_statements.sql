SELECT C.CUSTOMER_ID,
       C.CUSTOMER_NAME,
       C.EMAIL_ADDRESS,
       O.ORDER_COUNT,
       O.TOTAL_AMOUNT
  FROM CUSTOMER C
 INNER JOIN CUSTOMER_ORDER_SUMMARY O ON C.CUSTOMER_ID = O.CUSTOMER_ID
 WHERE C.IS_ACTIVE = 1
   AND O.TOTAL_AMOUNT > 100
 ORDER BY O.TOTAL_AMOUNT DESC,
          C.CUSTOMER_ID ASC
 LIMIT 250
  WITH UR;

WITH ACTIVE_CUSTOMERS AS ( SELECT C.CUSTOMER_ID,
                                  C.CUSTOMER_NAME,
                                  C.EMAIL_ADDRESS
                             FROM CUSTOMER C
                            WHERE C.IS_ACTIVE = 1 ),
     CUSTOMER_TOTALS AS ( SELECT O.CUSTOMER_ID,
                                  COUNT (*) AS ORDER_COUNT,
                                  SUM (O.ORDER_TOTAL) AS TOTAL_AMOUNT
                             FROM ORDER_HEADER O
                            WHERE O.ORDER_STATUS = 'PAID'
                            GROUP BY O.CUSTOMER_ID )
SELECT A.CUSTOMER_ID,
       A.CUSTOMER_NAME,
       A.EMAIL_ADDRESS,
       T.ORDER_COUNT,
       T.TOTAL_AMOUNT
  FROM ACTIVE_CUSTOMERS A
 INNER JOIN CUSTOMER_TOTALS T ON A.CUSTOMER_ID = T.CUSTOMER_ID
 WHERE T.TOTAL_AMOUNT > 100
 ORDER BY T.TOTAL_AMOUNT DESC
 LIMIT 250
  WITH UR;

INSERT INTO CUSTOMER_STATUS_HISTORY ( CUSTOMER_ID,
                                      OLD_STATUS_CODE,
                                      NEW_STATUS_CODE,
                                      CHANGE_REASON,
                                      CREATED_AT,
                                      CREATED_BY )
VALUES ( 1,
         'NEW',
         'ACTIVE',
         'MANUAL_CHANGE',
         CURRENT TIMESTAMP,
         CURRENT USER )
  WITH NC;

UPDATE CUSTOMER C
   SET C.STATUS_CODE = 'ACTIVE',
       C.UPDATED_AT = CURRENT TIMESTAMP,
       C.UPDATED_BY = CURRENT USER
 WHERE C.CUSTOMER_ID IN ( SELECT H.CUSTOMER_ID
                            FROM CUSTOMER_STATUS_HISTORY H
                           WHERE H.NEW_STATUS_CODE = 'ACTIVE' )
  WITH NC;
