# Oracle SQL / PL-SQL support

The same DBeaver external formatter command is used for DB2, PostgreSQL, T-SQL and Oracle:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Path\To\dbeaver-sql-formatter\formatter\format-dbeaver.ps1"
```

`formatter/format-dbeaver.ps1` delegates to the same full presentation pipeline used by the Windows UI. Dialect detection underneath automatically routes strong Oracle / PL-SQL syntax signals to `formatter/format-plsql.ps1`; ordinary ANSI SQL continues through the shared formatter.

## Covered in the first Oracle release

- normal `SELECT`, CTE and subquery formatting through the shared formatter
- Oracle `q'[...]'` alternative quoted strings
- PL-SQL `SELECT ... INTO ...`
- hierarchical queries with `START WITH` and `CONNECT BY`
- DML `RETURNING ... INTO`
- `INSERT ALL` and `INSERT FIRST`
- Oracle `MERGE` through the shared structural MERGE formatter
- bind variables such as `:P_ID`
- PL-SQL declarations and assignments (`:=`, `%TYPE`, `%ROWTYPE`)
- anonymous `DECLARE ... BEGIN ... EXCEPTION ... END;` blocks
- procedures, functions, packages, triggers and type bodies
- `IF / ELSIF / ELSE`, loops and CASE block indentation
- embedded SQL statements inside PL-SQL program units
- SQL*Plus-style `/` program-unit terminators
- Oracle signals such as `VARCHAR2`, `PLS_INTEGER`, `SYS_REFCURSOR`, `PRAGMA`, `FORALL`, `BULK COLLECT`, `DBMS_*` and `RAISE_APPLICATION_ERROR`

## Safety model

PL-SQL is treated as a program language around embedded SQL rather than flattened as one SQL statement. The Oracle engine formats embedded SQL units recursively, and the program-unit safety pass places those units back at the correct PL-SQL block indentation while retaining their relative SQL alignment.

Oracle alternative quoted literals are protected before whitespace or keyword processing so text inside `q'[...]'`, `q'{...}'`, `q'(...)'`, `q'<...>'` and custom-delimiter forms is not rewritten.

The formatter remains heuristic rather than a complete Oracle parser. When a construct cannot be understood safely, preserving valid PL-SQL takes priority over aggressive reformatting.

## DBeaver

No second formatter configuration is required. Configure DBeaver once to call `formatter/format-dbeaver.ps1`; the same `Ctrl + Shift + F` command can then be used in DB2, PostgreSQL, SQL Server/Azure SQL and Oracle editors.

For procedures, functions, packages, triggers and anonymous blocks, select the complete program unit before formatting, including the final `/` when it is present in the script.
