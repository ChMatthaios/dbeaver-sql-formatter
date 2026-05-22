CREATE OR REPLACE FUNCTION FN_CUSTOMER_RISK_SCORE
  (P_CUSTOMER_ID INTEGER,
  P_AS_OF_DATE DATE
)
RETURNS DECIMAL (10, 2)
LANGUAGE SQL
BEGIN
  RETURN (
    WITH BASE_EVENTS AS ( SELECT E.CUSTOMER_ID,
                                 E.EVENT_TYPE,
                                 E.EVENT_TS,
                                 E.RISK_WEIGHT,
                                 ROW_NUMBER ()
                                       OVER (PARTITION BY E.CUSTOMER_ID, E.EVENT_TYPE
                                                 ORDER BY E.EVENT_TS DESC, E.EVENT_ID DESC) AS RN
                            FROM CUSTOMER_EVENT E
                           WHERE E.CUSTOMER_ID = P_CUSTOMER_ID
                             AND DATE (E.EVENT_TS) <= P_AS_OF_DATE ),
         RISK_ROLLUP AS ( SELECT B.CUSTOMER_ID,
                                 SUM (
                                 CASE
                                   WHEN B.EVENT_TYPE = 'REFUND' THEN B.RISK_WEIGHT
                                   ELSE 0
                                 END) AS REFUND_RISK,
                                 SUM (
                                 CASE
                                   WHEN B.EVENT_TYPE = 'SUPPORT' THEN B.RISK_WEIGHT
                                   ELSE 0
                                 END) AS SUPPORT_RISK,
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
      WITH UR
  );
END;
