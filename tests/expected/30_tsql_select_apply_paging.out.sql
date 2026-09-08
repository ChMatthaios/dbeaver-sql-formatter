SELECT TOP (25) [c].[CustomerID],
       [c].[Name],
       ISNULL([c].[Email], N'') AS [Email]
  FROM [dbo].[Customer] [c] WITH (NOLOCK)
  OUTER APPLY (SELECT TOP (1) [o].[OrderID],
                      [o].[CreatedAt]
                 FROM [dbo].[Orders] [o]
                WHERE [o].[CustomerID] = [c].[CustomerID]
                ORDER BY [o].[CreatedAt] DESC) [last_order]
 WHERE [c].[IsActive] = 1
 ORDER BY [c].[CustomerID]
 OFFSET 20 ROWS
 FETCH NEXT 10 ROWS ONLY
 OPTION (RECOMPILE);
