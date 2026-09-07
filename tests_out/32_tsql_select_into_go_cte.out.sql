SELECT TOP (100) [c].[CustomerID],
       [c].[Name]
  INTO #active_customer
  FROM [dbo].[Customer] [c]
 WHERE [c].[IsActive] = 1;
GO
WITH recent_orders
  AS ( SELECT TOP (10) [o].[CustomerID],
              [o].[OrderID]
         FROM [dbo].[Orders] [o]
        ORDER BY [o].[CreatedAt] DESC )
SELECT [r].[CustomerID],
       [r].[OrderID]
  FROM recent_orders [r];
