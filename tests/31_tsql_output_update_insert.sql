update c
set c.Email = s.Email, c.UpdatedAt = sysdatetime()
output inserted.CustomerID, deleted.Email, inserted.Email
from [dbo].[Customer] c
join #stage s on c.CustomerID = s.CustomerID
where isnull(c.Email, N'') <> isnull(s.Email, N'')
option (recompile);

insert into [dbo].[Audit] ([CustomerID], [ActionName])
output inserted.[AuditID], inserted.[CustomerID]
values (@CustomerID, N'UPDATED');
