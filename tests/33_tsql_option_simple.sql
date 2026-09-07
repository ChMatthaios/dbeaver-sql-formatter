select top (5) [CustomerID]
from [dbo].[Customer]
where [IsActive] = 1
option (recompile);
