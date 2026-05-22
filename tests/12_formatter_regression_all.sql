SELECT * FROM CUSTOMER LIMIT 100 WITH UR;

SELECT CUSTOMER_ID, CUSTOMER_NAME, EMAIL_ADDRESS FROM CUSTOMER WHERE CUSTOMER_ID = 1 LIMIT 100 WITH UR;

INSERT INTO CUSTOMER_AUDIT (CUSTOMER_ID, ACTION_CODE, CREATED_AT) VALUES (1, 'CREATE', CURRENT TIMESTAMP) WITH NC;

UPDATE CUSTOMER SET EMAIL_ADDRESS = 'A@B.COM', UPDATED_AT = CURRENT TIMESTAMP WHERE CUSTOMER_ID = 1 WITH NC;

DELETE FROM CUSTOMER_SESSION WHERE CUSTOMER_ID = 1 WITH NC;

MERGE INTO CUSTOMER_TARGET T USING (SELECT CUSTOMER_ID, EMAIL_ADDRESS FROM CUSTOMER_SOURCE WHERE BATCH_ID = 1) S ON (T.CUSTOMER_ID = S.CUSTOMER_ID) WHEN MATCHED AND (T.EMAIL_ADDRESS <> S.EMAIL_ADDRESS) THEN UPDATE SET T.EMAIL_ADDRESS = S.EMAIL_ADDRESS, T.UPDATED_AT = CURRENT TIMESTAMP WHEN NOT MATCHED THEN INSERT (CUSTOMER_ID, EMAIL_ADDRESS, CREATED_AT) VALUES (S.CUSTOMER_ID, S.EMAIL_ADDRESS, CURRENT TIMESTAMP) WITH NC;
SELECT CUSTOMER_ID,
       CUSTOMER_NAME,
       EMAIL_ADDRESS
  FROM CUSTOMER
 WHERE CUSTOMER_ID = 1
 LIMIT 100
  WITH UR;

INSERT INTO CUSTOMER_AUDIT ( CUSTOMER_ID,
                             ACTION_CODE,
                             CREATED_AT )
VALUES ( 1,
         'CREATE',
         CURRENT TIMESTAMP )
  WITH NC;

UPDATE CUSTOMER
   SET EMAIL_ADDRESS = 'A@B.COM',
       UPDATED_AT = CURRENT TIMESTAMP
 WHERE CUSTOMER_ID = 1
  WITH NC;

DELETE FROM CUSTOMER_SESSION
 WHERE CUSTOMER_ID = 1
  WITH NC;

 MERGE INTO CUSTOMER_TARGET T
 USING ( SELECT CUSTOMER_ID,
                EMAIL_ADDRESS
           FROM CUSTOMER_SOURCE
          WHERE BATCH_ID = 1 ) S ON (T.CUSTOMER_ID = S.CUSTOMER_ID)
  WHEN MATCHED AND ( T.EMAIL_ADDRESS <> S.EMAIL_ADDRESS ) THEN
UPDATE
   SET T.EMAIL_ADDRESS = S.EMAIL_ADDRESS,
       T.UPDATED_AT = CURRENT TIMESTAMP
  WHEN NOT MATCHED THEN
INSERT ( CUSTOMER_ID,
         EMAIL_ADDRESS,
         CREATED_AT )
VALUES ( S.CUSTOMER_ID,
         S.EMAIL_ADDRESS,
         CURRENT TIMESTAMP )
  WITH NC;
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
WITH BASE_ORDERS AS ( SELECT O.CUSTOMER_ID,
                             O.ORDER_ID,
                             O.ORDER_DATE,
                             O.STATUS_CODE,
                             O.TOTAL_AMOUNT,
                             O.CURRENCY_CODE,
                             ROW_NUMBER ()
                                   OVER (PARTITION BY O.CUSTOMER_ID
                                             ORDER BY O.ORDER_DATE DESC, O.ORDER_ID DESC) AS RN
                        FROM ORDER_HEADER O
                       WHERE O.BATCH_ID = 20260520
                         AND O.STATUS_CODE IN ('PAID', 'SHIPPED', 'CLOSED') ),
     CUSTOMER_TOTALS AS ( SELECT B.CUSTOMER_ID,
                                 COUNT (*) AS ORDER_COUNT,
                                 SUM (B.TOTAL_AMOUNT) AS TOTAL_AMOUNT,
                                 MAX (B.ORDER_DATE) AS LAST_ORDER_DATE
                            FROM BASE_ORDERS B
                           WHERE B.RN <= 10
                           GROUP BY B.CUSTOMER_ID )
SELECT C.CUSTOMER_ID,
       C.CUSTOMER_NAME,
       C.EMAIL_ADDRESS,
       CT.ORDER_COUNT,
       CT.TOTAL_AMOUNT,
       CASE
         WHEN CT.TOTAL_AMOUNT >= 10000 THEN 'VIP'
         WHEN CT.TOTAL_AMOUNT >= 5000 THEN 'GOLD'
         WHEN CT.TOTAL_AMOUNT >= 1000 THEN 'SILVER'
         ELSE 'STANDARD'
       END AS CUSTOMER_SEGMENT
  FROM CUSTOMER C
 INNER JOIN CUSTOMER_TOTALS CT ON C.CUSTOMER_ID = CT.CUSTOMER_ID
  LEFT JOIN BASE_ORDERS BO ON C.CUSTOMER_ID = BO.CUSTOMER_ID AND BO.RN = 1
 WHERE C.IS_ACTIVE = 1
   AND (CT.TOTAL_AMOUNT > 0 OR BO.STATUS_CODE = 'PAID')
 ORDER BY CT.TOTAL_AMOUNT DESC,
          C.CUSTOMER_ID ASC
 LIMIT 250
  WITH UR;

 MERGE INTO TGT_CUSTOMER_SUMMARY T
 USING ( SELECT C.CUSTOMER_ID,
                C.CUSTOMER_NAME,
                C.EMAIL_ADDRESS,
                CT.ORDER_COUNT,
                CT.TOTAL_AMOUNT,
                CT.LAST_ORDER_DATE,
                CASE
                  WHEN CT.TOTAL_AMOUNT >= 10000 THEN 'VIP'
                  WHEN CT.TOTAL_AMOUNT >= 5000 THEN 'GOLD'
                  ELSE 'STANDARD'
                END AS SEGMENT_CODE,
                ROW_NUMBER ()
                      OVER (PARTITION BY C.CUSTOMER_ID
                                ORDER BY CT.LAST_ORDER_DATE DESC, C.UPDATED_AT DESC) AS RN
           FROM CUSTOMER C
          INNER JOIN CUSTOMER_TOTALS CT ON C.CUSTOMER_ID = CT.CUSTOMER_ID
          WHERE C.IS_ACTIVE = 1
            AND CT.ORDER_COUNT > 0 ) S ON (T.CUSTOMER_ID = S.CUSTOMER_ID AND S.RN = 1)
  WHEN MATCHED AND ( COALESCE(T.CUSTOMER_NAME, '') <> COALESCE(S.CUSTOMER_NAME, '')
                  OR COALESCE(T.EMAIL_ADDRESS, '') <> COALESCE(S.EMAIL_ADDRESS, '')
                  OR COALESCE(T.SEGMENT_CODE, '') <> COALESCE(S.SEGMENT_CODE, '')
                  OR COALESCE(T.TOTAL_AMOUNT, 0) <> COALESCE(S.TOTAL_AMOUNT, 0) ) THEN
UPDATE
   SET T.CUSTOMER_NAME = S.CUSTOMER_NAME,
       T.EMAIL_ADDRESS = S.EMAIL_ADDRESS,
       T.ORDER_COUNT = S.ORDER_COUNT,
       T.TOTAL_AMOUNT = S.TOTAL_AMOUNT,
       T.LAST_ORDER_DATE = S.LAST_ORDER_DATE,
       T.SEGMENT_CODE = S.SEGMENT_CODE,
       T.UPDATED_AT = CURRENT TIMESTAMP,
       T.UPDATED_BY = CURRENT USER
  WHEN NOT MATCHED THEN
INSERT ( CUSTOMER_ID,
         CUSTOMER_NAME,
         EMAIL_ADDRESS,
         ORDER_COUNT,
         TOTAL_AMOUNT,
         LAST_ORDER_DATE,
         SEGMENT_CODE,
         CREATED_AT,
         CREATED_BY,
         UPDATED_AT,
         UPDATED_BY )
VALUES ( S.CUSTOMER_ID,
         S.CUSTOMER_NAME,
         S.EMAIL_ADDRESS,
         S.ORDER_COUNT,
         S.TOTAL_AMOUNT,
         S.LAST_ORDER_DATE,
         S.SEGMENT_CODE,
         CURRENT TIMESTAMP,
         CURRENT USER,
         CURRENT TIMESTAMP,
         CURRENT USER )
  WITH NC;
WITH SOURCE_EVENTS AS ( SELECT E.CUSTOMER_ID,
                               E.EVENT_ID,
                               E.EVENT_TYPE,
                               E.EVENT_TS,
                               E.SOURCE_SYSTEM,
                               E.PAYLOAD_HASH,
                               ROW_NUMBER ()
                                     OVER (PARTITION BY E.CUSTOMER_ID, E.EVENT_TYPE
                                               ORDER BY E.EVENT_TS DESC, E.INGESTED_TS DESC, E.EVENT_ID DESC) AS RN
                          FROM CUSTOMER_EVENT E
                         WHERE E.BATCH_ID = 20260520
                           AND E.EVENT_TYPE IN ('LOGIN', 'PURCHASE', 'REFUND', 'SUPPORT')
                           AND EXISTS ( SELECT 1
                                          FROM CUSTOMER C
                                         WHERE C.CUSTOMER_ID = E.CUSTOMER_ID
                                           AND C.IS_ACTIVE = 1 ) ),
     EVENT_ROLLUP AS ( SELECT S.CUSTOMER_ID,
                              COUNT (*) AS EVENT_COUNT,
                              SUM (CASE WHEN S.EVENT_TYPE = 'PURCHASE' THEN 1 ELSE 0 END) AS PURCHASE_COUNT,
                              MAX (S.EVENT_TS) AS LAST_EVENT_TS
                         FROM SOURCE_EVENTS S
                        WHERE S.RN = 1
                        GROUP BY S.CUSTOMER_ID
                       HAVING COUNT (*) > 0 ),
     CUSTOMER_SCORE AS ( SELECT R.CUSTOMER_ID,
                                R.EVENT_COUNT,
                                R.PURCHASE_COUNT,
                                R.LAST_EVENT_TS,
                                CASE
                                  WHEN R.PURCHASE_COUNT >= 10 THEN 'A'
                                  WHEN R.PURCHASE_COUNT >= 5 THEN 'B'
                                  WHEN R.EVENT_COUNT >= 3 THEN 'C'
                                  ELSE 'D'
                                END AS SCORE_CODE
                           FROM EVENT_ROLLUP R )
SELECT C.CUSTOMER_ID,
       C.CUSTOMER_NAME,
       C.EMAIL_ADDRESS,
       S.EVENT_COUNT,
       S.PURCHASE_COUNT,
       S.LAST_EVENT_TS,
       S.SCORE_CODE
  FROM CUSTOMER C
 INNER JOIN CUSTOMER_SCORE S ON C.CUSTOMER_ID = S.CUSTOMER_ID
 WHERE C.IS_ACTIVE = 1
   AND (   S.SCORE_CODE IN ('A', 'B')
        OR C.CUSTOMER_ID IN ( SELECT P.CUSTOMER_ID
                                FROM CUSTOMER_PREFERENCE P
                               WHERE P.PREFERENCE_CODE = 'PRIORITY'
                                 AND P.IS_ENABLED = 1 ) )
 ORDER BY S.PURCHASE_COUNT DESC,
          S.EVENT_COUNT DESC,
          C.CUSTOMER_ID ASC
 LIMIT 500
  WITH UR;

 MERGE INTO TGT_CUSTOMER_EVENT_SCORE T
 USING ( SELECT C.CUSTOMER_ID,
                C.CUSTOMER_NAME,
                C.EMAIL_ADDRESS,
                S.EVENT_COUNT,
                S.PURCHASE_COUNT,
                S.LAST_EVENT_TS,
                S.SCORE_CODE,
                ROW_NUMBER ()
                      OVER (PARTITION BY C.CUSTOMER_ID
                                ORDER BY S.LAST_EVENT_TS DESC, C.UPDATED_AT DESC, C.CUSTOMER_ID ASC) AS RN
           FROM CUSTOMER C
          INNER JOIN CUSTOMER_SCORE S ON C.CUSTOMER_ID = S.CUSTOMER_ID
          WHERE C.IS_ACTIVE = 1
            AND (   S.SCORE_CODE IN ('A', 'B', 'C')
                 OR EXISTS ( SELECT 1
                               FROM CUSTOMER_OVERRIDE O
                              WHERE O.CUSTOMER_ID = C.CUSTOMER_ID
                                AND O.OVERRIDE_CODE = 'INCLUDE_IN_SCORE'
                                AND O.IS_ACTIVE = 1 ) ) ) S ON (T.CUSTOMER_ID = S.CUSTOMER_ID AND S.RN = 1)
  WHEN MATCHED AND ( COALESCE(T.CUSTOMER_NAME, '') <> COALESCE(S.CUSTOMER_NAME, '')
                  OR COALESCE(T.EMAIL_ADDRESS, '') <> COALESCE(S.EMAIL_ADDRESS, '')
                  OR COALESCE(T.EVENT_COUNT, 0) <> COALESCE(S.EVENT_COUNT, 0)
                  OR COALESCE(T.PURCHASE_COUNT, 0) <> COALESCE(S.PURCHASE_COUNT, 0)
                  OR COALESCE(T.SCORE_CODE, '') <> COALESCE(S.SCORE_CODE, '') ) THEN
UPDATE
   SET T.CUSTOMER_NAME = S.CUSTOMER_NAME,
       T.EMAIL_ADDRESS = S.EMAIL_ADDRESS,
       T.EVENT_COUNT = S.EVENT_COUNT,
       T.PURCHASE_COUNT = S.PURCHASE_COUNT,
       T.LAST_EVENT_TS = S.LAST_EVENT_TS,
       T.SCORE_CODE = S.SCORE_CODE,
       T.UPDATED_AT = CURRENT TIMESTAMP,
       T.UPDATED_BY = CURRENT USER
  WHEN NOT MATCHED THEN
INSERT ( CUSTOMER_ID,
         CUSTOMER_NAME,
         EMAIL_ADDRESS,
         EVENT_COUNT,
         PURCHASE_COUNT,
         LAST_EVENT_TS,
         SCORE_CODE,
         CREATED_AT,
         CREATED_BY,
         UPDATED_AT,
         UPDATED_BY )
VALUES ( S.CUSTOMER_ID,
         S.CUSTOMER_NAME,
         S.EMAIL_ADDRESS,
         S.EVENT_COUNT,
         S.PURCHASE_COUNT,
         S.LAST_EVENT_TS,
         S.SCORE_CODE,
         CURRENT TIMESTAMP,
         CURRENT USER,
         CURRENT TIMESTAMP,
         CURRENT USER )
  WITH NC;
CREATE OR REPLACE PROCEDURE SP_REFRESH_CUSTOMER_STATUS
(
    IN P_CUSTOMER_ID INTEGER
)
LANGUAGE SQL
BEGIN
    UPDATE CUSTOMER
       SET STATUS_CODE = 'ACTIVE',
           UPDATED_AT = CURRENT TIMESTAMP,
           UPDATED_BY = CURRENT USER
     WHERE CUSTOMER_ID = P_CUSTOMER_ID
      WITH NC;
END;
CREATE OR REPLACE PROCEDURE SP_LOAD_CUSTOMER_SUMMARY
(
    IN P_BATCH_ID INTEGER
)
LANGUAGE SQL
BEGIN
    INSERT INTO CUSTOMER_SUMMARY ( CUSTOMER_ID,
                                   ORDER_COUNT,
                                   TOTAL_AMOUNT,
                                   CREATED_AT,
                                   CREATED_BY )
    SELECT O.CUSTOMER_ID,
           COUNT (*) AS ORDER_COUNT,
           SUM (O.ORDER_TOTAL) AS TOTAL_AMOUNT,
           CURRENT TIMESTAMP AS CREATED_AT,
           CURRENT USER AS CREATED_BY
      FROM ORDER_HEADER O
     WHERE O.BATCH_ID = P_BATCH_ID
       AND O.ORDER_STATUS = 'PAID'
     GROUP BY O.CUSTOMER_ID
    HAVING SUM (O.ORDER_TOTAL) > 0
      WITH NC;

    UPDATE BATCH_CONTROL
       SET FINISHED_AT = CURRENT TIMESTAMP,
           STATUS_CODE = 'DONE'
     WHERE BATCH_ID = P_BATCH_ID
      WITH NC;
END;
CREATE OR REPLACE PROCEDURE SP_MERGE_CUSTOMER_EVENT_SCORE
(
    IN P_BATCH_ID INTEGER,
    IN P_FORCE_REFRESH SMALLINT
)
LANGUAGE SQL
BEGIN
    DECLARE V_STARTED_AT TIMESTAMP;
    DECLARE V_ROWS_UPDATED INTEGER DEFAULT 0;

    SET V_STARTED_AT = CURRENT TIMESTAMP;

    WITH SOURCE_EVENTS AS ( SELECT E.CUSTOMER_ID,
                                   E.EVENT_ID,
                                   E.EVENT_TYPE,
                                   E.EVENT_TS,
                                   E.SOURCE_SYSTEM,
                                   E.PAYLOAD_HASH,
                                   ROW_NUMBER ()
                                         OVER (PARTITION BY E.CUSTOMER_ID, E.EVENT_TYPE
                                                   ORDER BY E.EVENT_TS DESC, E.INGESTED_TS DESC, E.EVENT_ID DESC) AS RN
                              FROM CUSTOMER_EVENT E
                             WHERE E.BATCH_ID = P_BATCH_ID
                               AND E.EVENT_TYPE IN ('LOGIN', 'PURCHASE', 'REFUND', 'SUPPORT') ),
         EVENT_ROLLUP AS ( SELECT S.CUSTOMER_ID,
                                  COUNT (*) AS EVENT_COUNT,
                                  SUM (CASE WHEN S.EVENT_TYPE = 'PURCHASE' THEN 1 ELSE 0 END) AS PURCHASE_COUNT,
                                  MAX (S.EVENT_TS) AS LAST_EVENT_TS
                             FROM SOURCE_EVENTS S
                            WHERE S.RN = 1
                            GROUP BY S.CUSTOMER_ID )
    SELECT COUNT (*)
      INTO V_ROWS_UPDATED
      FROM EVENT_ROLLUP
      WITH UR;

     MERGE INTO TGT_CUSTOMER_EVENT_SCORE T
     USING ( SELECT C.CUSTOMER_ID,
                    C.CUSTOMER_NAME,
                    C.EMAIL_ADDRESS,
                    R.EVENT_COUNT,
                    R.PURCHASE_COUNT,
                    R.LAST_EVENT_TS,
                    CASE
                      WHEN R.PURCHASE_COUNT >= 10 THEN 'A'
                      WHEN R.PURCHASE_COUNT >= 5 THEN 'B'
                      WHEN R.EVENT_COUNT >= 3 THEN 'C'
                      ELSE 'D'
                    END AS SCORE_CODE,
                    ROW_NUMBER ()
                          OVER (PARTITION BY C.CUSTOMER_ID
                                    ORDER BY R.LAST_EVENT_TS DESC, C.UPDATED_AT DESC) AS RN
               FROM CUSTOMER C
              INNER JOIN EVENT_ROLLUP R ON C.CUSTOMER_ID = R.CUSTOMER_ID
              WHERE C.IS_ACTIVE = 1
                AND (P_FORCE_REFRESH = 1 OR R.EVENT_COUNT > 0) ) S ON (T.CUSTOMER_ID = S.CUSTOMER_ID AND S.RN = 1)
      WHEN MATCHED AND ( COALESCE(T.CUSTOMER_NAME, '') <> COALESCE(S.CUSTOMER_NAME, '')
                      OR COALESCE(T.EMAIL_ADDRESS, '') <> COALESCE(S.EMAIL_ADDRESS, '')
                      OR COALESCE(T.EVENT_COUNT, 0) <> COALESCE(S.EVENT_COUNT, 0)
                      OR COALESCE(T.PURCHASE_COUNT, 0) <> COALESCE(S.PURCHASE_COUNT, 0)
                      OR COALESCE(T.SCORE_CODE, '') <> COALESCE(S.SCORE_CODE, '') ) THEN
    UPDATE
       SET T.CUSTOMER_NAME = S.CUSTOMER_NAME,
           T.EMAIL_ADDRESS = S.EMAIL_ADDRESS,
           T.EVENT_COUNT = S.EVENT_COUNT,
           T.PURCHASE_COUNT = S.PURCHASE_COUNT,
           T.LAST_EVENT_TS = S.LAST_EVENT_TS,
           T.SCORE_CODE = S.SCORE_CODE,
           T.UPDATED_AT = CURRENT TIMESTAMP,
           T.UPDATED_BY = CURRENT USER
      WHEN NOT MATCHED THEN
    INSERT ( CUSTOMER_ID,
             CUSTOMER_NAME,
             EMAIL_ADDRESS,
             EVENT_COUNT,
             PURCHASE_COUNT,
             LAST_EVENT_TS,
             SCORE_CODE,
             CREATED_AT,
             CREATED_BY,
             UPDATED_AT,
             UPDATED_BY )
    VALUES ( S.CUSTOMER_ID,
             S.CUSTOMER_NAME,
             S.EMAIL_ADDRESS,
             S.EVENT_COUNT,
             S.PURCHASE_COUNT,
             S.LAST_EVENT_TS,
             S.SCORE_CODE,
             CURRENT TIMESTAMP,
             CURRENT USER,
             CURRENT TIMESTAMP,
             CURRENT USER )
      WITH NC;

    INSERT INTO PROCEDURE_AUDIT_LOG ( PROCEDURE_NAME,
                                      BATCH_ID,
                                      STARTED_AT,
                                      FINISHED_AT,
                                      ROW_COUNT,
                                      CREATED_BY )
    VALUES ( 'SP_MERGE_CUSTOMER_EVENT_SCORE',
             P_BATCH_ID,
             V_STARTED_AT,
             CURRENT TIMESTAMP,
             V_ROWS_UPDATED,
             CURRENT USER )
      WITH NC;
END;
CREATE OR REPLACE FUNCTION FN_CUSTOMER_STATUS
(
    P_CUSTOMER_ID INTEGER
)
RETURNS VARCHAR(20)
LANGUAGE SQL
BEGIN
    RETURN ( SELECT STATUS_CODE
               FROM CUSTOMER
              WHERE CUSTOMER_ID = P_CUSTOMER_ID
              FETCH FIRST 1 ROW ONLY );
END;
CREATE OR REPLACE FUNCTION FN_CUSTOMER_SEGMENT
(
    P_CUSTOMER_ID INTEGER
)
RETURNS VARCHAR(20)
LANGUAGE SQL
BEGIN
    RETURN ( SELECT CASE
                     WHEN SUM (O.ORDER_TOTAL) >= 10000 THEN 'VIP'
                     WHEN SUM (O.ORDER_TOTAL) >= 5000 THEN 'GOLD'
                     WHEN SUM (O.ORDER_TOTAL) >= 1000 THEN 'SILVER'
                     ELSE 'STANDARD'
                   END AS SEGMENT_CODE
               FROM ORDER_HEADER O
              WHERE O.CUSTOMER_ID = P_CUSTOMER_ID
                AND O.ORDER_STATUS = 'PAID'
              WITH UR );
END;
CREATE OR REPLACE FUNCTION FN_CUSTOMER_RISK_SCORE
(
    P_CUSTOMER_ID INTEGER,
    P_AS_OF_DATE DATE
)
RETURNS DECIMAL(10, 2)
LANGUAGE SQL
BEGIN
    RETURN ( WITH BASE_EVENTS AS ( SELECT E.CUSTOMER_ID,
                                          E.EVENT_TYPE,
                                          E.EVENT_TS,
                                          E.RISK_WEIGHT,
                                          ROW_NUMBER ()
                                                OVER (PARTITION BY E.CUSTOMER_ID, E.EVENT_TYPE
                                                          ORDER BY E.EVENT_TS DESC, E.EVENT_ID DESC) AS RN
                                     FROM CUSTOMER_EVENT E
                                    WHERE E.CUSTOMER_ID = P_CUSTOMER_ID
                                      AND DATE(E.EVENT_TS) <= P_AS_OF_DATE ),
                  RISK_ROLLUP AS ( SELECT B.CUSTOMER_ID,
                                          SUM (CASE WHEN B.EVENT_TYPE = 'REFUND' THEN B.RISK_WEIGHT ELSE 0 END) AS REFUND_RISK,
                                          SUM (CASE WHEN B.EVENT_TYPE = 'SUPPORT' THEN B.RISK_WEIGHT ELSE 0 END) AS SUPPORT_RISK,
                                          SUM (B.RISK_WEIGHT) AS TOTAL_RISK
                                     FROM BASE_EVENTS B
                                    WHERE B.RN = 1
                                    GROUP BY B.CUSTOMER_ID )
             SELECT CASE
                      WHEN R.TOTAL_RISK IS NULL THEN 0
                      WHEN R.TOTAL_RISK > 100 THEN 100
                      ELSE R.TOTAL_RISK
                    END AS RISK_SCORE
               FROM RISK_ROLLUP R
              WITH UR );
END;
