/*
 * SQL Server / T-SQL formatter stress test.
 * Intentionally compact input covering T-SQL-specific syntax.
 */

-- 01. TOP + bracketed identifiers + APPLY + window function
select top(25) c.[CustomerId],isnull(c.[Name],N'') as [Name],x.[LastOrderDate],x.[TotalAmount],row_number() over(partition by c.[CountryCode] order by x.[TotalAmount] desc,c.[CustomerId]) as [CountryRank] from [dbo].[Customer] c outer apply(select top(1) o.[OrderDate] as [LastOrderDate],o.[TotalAmount] from [dbo].[Order] o where o.[CustomerId]=c.[CustomerId] order by o.[OrderDate] desc,o.[OrderId] desc) x where c.[IsActive]=1 order by x.[TotalAmount] desc,c.[CustomerId];

-- 02. CTE + SELECT INTO temp table
with order_totals as(select o.[CustomerId],count_big(*) as [OrderCount],sum(o.[TotalAmount]) as [TotalAmount],max(o.[OrderDate]) as [LastOrderDate] from [dbo].[Order] o with(nolock) where o.[StatusCode] in(N'PAID',N'SHIPPED') group by o.[CustomerId]) select c.[CustomerId],c.[Name],isnull(t.[OrderCount],0) as [OrderCount],isnull(t.[TotalAmount],0) as [TotalAmount] into #CustomerSummary from [dbo].[Customer] c left join order_totals t on t.[CustomerId]=c.[CustomerId] where c.[IsActive]=1;

-- 03. INSERT + OUTPUT
insert into [dbo].[CustomerAudit]([CustomerId],[ActionCode],[Payload],[CreatedAt]) output inserted.[AuditId],inserted.[CustomerId],inserted.[CreatedAt] select c.[CustomerId],N'REVIEW',concat(N'{"name":"',isnull(c.[Name],N''),N'"}'),sysdatetime() from [dbo].[Customer] c where c.[IsActive]=1 and exists(select 1 from [dbo].[CustomerBlacklist] b where b.[CustomerId]=c.[CustomerId] and b.[ActiveFlag]=1);

-- 04. UPDATE ... FROM + OUTPUT
update c set c.[SegmentCode]=case when s.[TotalAmount]>=25000 and s.[OrderCount]>=3 then N'PLATINUM' when s.[TotalAmount]>=10000 then N'GOLD' else N'STANDARD' end,c.[UpdatedAt]=sysdatetime() output inserted.[CustomerId],deleted.[SegmentCode] as [OldSegment],inserted.[SegmentCode] as [NewSegment] from [dbo].[Customer] c inner join #CustomerSummary s on s.[CustomerId]=c.[CustomerId] where c.[IsActive]=1;

-- 05. DELETE alias FROM + JOIN + OUTPUT
delete s output deleted.[StageId],deleted.[CustomerId] from [dbo].[CustomerStage] s inner join [dbo].[LoadControl] lc on lc.[LoadBatchId]=s.[LoadBatchId] where s.[LoadBatchId]=@LoadBatchId and lc.[StatusCode]=N'FAILED' and not exists(select 1 from [dbo].[Customer] c where c.[ExternalCustomerId]=s.[ExternalCustomerId]);

-- 06. OFFSET/FETCH + OPTION
select c.[CustomerId],c.[Name],c.[CountryCode] from [dbo].[Customer] c where c.[IsActive]=1 order by c.[CustomerId] offset @Offset rows fetch next @PageSize rows only option(recompile);

-- 07. FOR JSON
select c.[CustomerId] as [id],c.[Name] as [name],c.[CountryCode] as [country] from [dbo].[Customer] c where c.[IsActive]=1 order by c.[CustomerId] for json path,root('customers');
