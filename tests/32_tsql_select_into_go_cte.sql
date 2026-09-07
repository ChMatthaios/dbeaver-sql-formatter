select top (100) [c].[CustomerID], [c].[Name]
into #active_customer
from [dbo].[Customer] [c]
where [c].[IsActive] = 1;
go
;with recent_orders as (
  select top (10) [o].[CustomerID], [o].[OrderID]
  from [dbo].[Orders] [o]
  order by [o].[CreatedAt] desc
)
select [r].[CustomerID], [r].[OrderID]
from recent_orders [r];
