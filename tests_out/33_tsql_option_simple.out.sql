SELECT TOP (5) [CustomerID]
  FROM [dbo].[Customer]
 WHERE [IsActive] = 1
 OPTION (RECOMPILE);
