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
                                SUM (
                                CASE
                                  WHEN S.EVENT_TYPE = 'PURCHASE' THEN 1
                                  ELSE 0
                                END) AS PURCHASE_COUNT,
                                MAX (S.EVENT_TS) AS LAST_EVENT_TS
                           FROM SOURCE_EVENTS S
                          WHERE S.RN = 1
                          GROUP BY S.CUSTOMER_ID )
  SELECT COUNT (*) INTO V_ROWS_UPDATED
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
            WHERE C.IS_ACTIVE = 1 AND (P_FORCE_REFRESH = 1 OR R.EVENT_COUNT > 0) ) S
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
