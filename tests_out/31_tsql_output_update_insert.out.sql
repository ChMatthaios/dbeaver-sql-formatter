UPDATE c
   SET c.Email = s.Email,
       c.UpdatedAt = SYSDATETIME()
OUTPUT INSERTED.CustomerID, DELETED.Email, INSERTED.Email
  FROM [dbo].[Customer] c
  JOIN #stage s ON c.CustomerID = s.CustomerID
 WHERE ISNULL(c.Email, N'') <> ISNULL(s.Email, N'')
 OPTION (RECOMPILE);

INSERT INTO [dbo].[Audit] ( [CustomerID], [ActionName] )
OUTPUT INSERTED.[AuditID], INSERTED.[CustomerID]
VALUES (@CustomerID, N'UPDATED');
