/*
 * SQL Server / T-SQL stored-object formatter stress test.
 * For DBeaver, select one complete object/batch at a time before Ctrl+Shift+F.
 */

-- 01. VIEW
create or alter view [reporting].[CustomerOrderSummary] as select c.[CustomerId],c.[Name],count_big(o.[OrderId]) as [OrderCount],isnull(sum(o.[TotalAmount]),0) as [TotalAmount],max(o.[OrderDate]) as [LastOrderDate] from [dbo].[Customer] c left join [dbo].[Order] o on o.[CustomerId]=c.[CustomerId] where c.[IsActive]=1 group by c.[CustomerId],c.[Name];
go

-- 02. PROCEDURE with TRY/CATCH, CTE and MERGE
create or alter procedure [reporting].[RefreshCustomerSummary] @LoadBatchId bigint as begin set nocount on;begin try;with src as(select o.[CustomerId],count_big(*) as [OrderCount],sum(o.[TotalAmount]) as [TotalAmount],max(o.[OrderDate]) as [LastOrderDate] from [dbo].[Order] o where o.[StatusCode] in(N'PAID',N'SHIPPED') group by o.[CustomerId]) merge [reporting].[CustomerSummary] as t using src as s on s.[CustomerId]=t.[CustomerId] when matched then update set t.[OrderCount]=s.[OrderCount],t.[TotalAmount]=s.[TotalAmount],t.[LastOrderDate]=s.[LastOrderDate],t.[UpdatedAt]=sysdatetime() when not matched then insert([CustomerId],[OrderCount],[TotalAmount],[LastOrderDate],[LoadBatchId]) values(s.[CustomerId],s.[OrderCount],s.[TotalAmount],s.[LastOrderDate],@LoadBatchId);end try begin catch;throw;end catch;end;
go

-- 03. Scalar function
create or alter function [reporting].[CustomerSegment](@TotalAmount decimal(18,2),@OrderCount bigint) returns nvarchar(20) as begin return case when @TotalAmount>=25000 and @OrderCount>=3 then N'PLATINUM' when @TotalAmount>=10000 then N'GOLD' else N'STANDARD' end;end;
go

-- 04. Trigger
create or alter trigger [dbo].[trg_CustomerStatusAudit] on [dbo].[Customer] after update as begin set nocount on;insert into [dbo].[CustomerStatusAudit]([CustomerId],[OldStatusCode],[NewStatusCode],[ChangedAt]) select i.[CustomerId],d.[StatusCode],i.[StatusCode],sysdatetime() from inserted i inner join deleted d on d.[CustomerId]=i.[CustomerId] where isnull(i.[StatusCode],N'')<>isnull(d.[StatusCode],N'');end;
go
