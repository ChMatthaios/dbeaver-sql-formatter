select top (25) [c].[CustomerID], [c].[Name], isnull([c].[Email], N'') as [Email]
from [dbo].[Customer] [c] with (nolock)
outer apply (
  select top (1) [o].[OrderID], [o].[CreatedAt]
  from [dbo].[Orders] [o]
  where [o].[CustomerID] = [c].[CustomerID]
  order by [o].[CreatedAt] desc
) [last_order]
where [c].[IsActive] = 1
order by [c].[CustomerID]
offset 20 rows fetch next 10 rows only
option (recompile);
