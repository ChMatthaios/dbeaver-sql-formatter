# PostgreSQL support

The same DBeaver external formatter command is used for DB2 and PostgreSQL:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Path\To\dbeaver-sql-formatter\formatter\format-dbeaver.ps1"
```

`formatter/format-dbeaver.ps1` delegates to the same full presentation pipeline used by the Windows UI. Dialect detection underneath automatically routes strong PostgreSQL syntax signals to `formatter/format-postgresql.ps1`; ordinary ANSI SQL continues through the shared core formatter.

## Covered in the first PostgreSQL release

- normal SELECT / CTE / subquery formatting through the shared formatter
- `DISTINCT ON (...)`
- PostgreSQL casts and JSON operators such as `::`, `->`, `->>`
- `ILIKE`
- `OFFSET`
- `FOR UPDATE`, `FOR SHARE`, key-share variants, `NOWAIT`, `SKIP LOCKED`
- `INSERT ... ON CONFLICT ... DO NOTHING`
- `INSERT ... ON CONFLICT ... DO UPDATE`
- `RETURNING`
- `UPDATE ... FROM`
- `DELETE ... USING`
- `WITH RECURSIVE`
- `CREATE TEMP/TEMPORARY TABLE ... AS SELECT`
- PostgreSQL keywords such as `TRUE`, `FALSE`, `LATERAL`, `FILTER`, `ARRAY`

## PL/pgSQL safety

Dollar-quoted function/procedure bodies (`$$...$$` and `$tag$...$tag$`) are protected before any whitespace or keyword processing. The body itself is preserved rather than aggressively reformatted, preventing damage to embedded PL/pgSQL statements, strings, comments, or internal semicolons.

## DBeaver

No second formatter configuration is required. Configure DBeaver once to call `formatter/format-dbeaver.ps1`; the same `Ctrl + Shift + F` command can then be used in DB2 and PostgreSQL editors.

For best results, select one complete SQL statement before formatting, especially for functions/procedures and large scripts.
