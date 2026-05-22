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
                           AND EXISTS (SELECT 1
                                         FROM CUSTOMER C
                                        WHERE C.CUSTOMER_ID = E.CUSTOMER_ID
                                          AND C.IS_ACTIVE = 1) ),
     EVENT_ROLLUP AS ( SELECT S.CUSTOMER_ID,
                              COUNT (*) AS EVENT_COUNT,
                              SUM (
                              CASE
                                WHEN S.EVENT_TYPE = 'PURCHASE' THEN 1
                                ELSE 0
                              END) AS PURCHASE_COUNT,
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
        OR C.CUSTOMER_ID IN (SELECT P.CUSTOMER_ID
                               FROM CUSTOMER_PREFERENCE P
                              WHERE P.PREFERENCE_CODE = 'PRIORITY'
                                AND P.IS_ENABLED = 1) )
 ORDER BY S.PURCHASE_COUNT DESC, S.EVENT_COUNT DESC, C.CUSTOMER_ID ASC
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
        OR EXISTS (SELECT 1
                     FROM CUSTOMER_OVERRIDE O
                    WHERE O.CUSTOMER_ID = C.CUSTOMER_ID
                      AND O.OVERRIDE_CODE = 'INCLUDE_IN_SCORE'
                      AND O.IS_ACTIVE = 1) ) ) S
        ON (T.CUSTOMER_ID = S.CUSTOMER_ID AND S.RN = 1)
  WHEN MATCHED AND (    COALESCE (T.CUSTOMER_NAME, '') <> COALESCE (S.CUSTOMER_NAME, '')
                     OR COALESCE (T.EMAIL_ADDRESS, '') <> COALESCE (S.EMAIL_ADDRESS, '')
                     OR COALESCE (T.EVENT_COUNT, 0) <> COALESCE (S.EVENT_COUNT, 0)
                     OR COALESCE (T.PURCHASE_COUNT, 0) <> COALESCE (S.PURCHASE_COUNT, 0)
                     OR COALESCE (T.SCORE_CODE, '') <> COALESCE (S.SCORE_CODE, '') ) THEN
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
