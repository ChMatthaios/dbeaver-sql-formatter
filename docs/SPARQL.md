# SPARQL support

The same DBeaver external formatter command can format SPARQL as well as the supported SQL dialects:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Path\To\dbeaver-sql-formatter\formatter\format-dbeaver.ps1"
```

`formatter/format-dbeaver.ps1` delegates to the same full presentation pipeline used by the Windows UI. Strong SPARQL syntax signals are routed underneath to `formatter/format-sparql.ps1`. The SPARQL path is isolated from SQL polish passes so RDF graph syntax is never treated as SQL.

## Covered

- `PREFIX` and `BASE` prologues
- `SELECT`, `ASK`, `CONSTRUCT`, and `DESCRIBE`
- graph-pattern `{ ... }` indentation
- triple patterns and `;` predicate lists
- `OPTIONAL`, `UNION`, `MINUS`, `GRAPH`, and `SERVICE`
- `FILTER`, `BIND`, `VALUES`, and nested subqueries
- `GROUP BY`, `HAVING`, `ORDER BY`, `LIMIT`, and `OFFSET`
- aggregates and common SPARQL built-in functions
- SPARQL Update forms including `INSERT DATA`, `DELETE DATA`, `DELETE WHERE`, and combined `DELETE` / `INSERT` updates
- `WITH` and `USING` update clauses
- RDF string literals, language tags, datatype markers (`^^`), IRIs, prefixed names, and variables
- `#` comments inside SPARQL input
- the repository-wide configurable line margin

## Formatting philosophy

SPARQL graph patterns are formatted recursively using the same general philosophy as nested SQL queries: format the inner structure first, then place it at the correct indentation. Braces increase indentation by two spaces. Triple-pattern terminators reset continuation indentation, while predicate-list semicolons continue the next predicate at an additional two spaces.

Keywords are uppercased, while IRIs, prefixed names, variables, RDF literals, and the SPARQL/Turtle shorthand predicate `a` are preserved.

## DBeaver

No second formatter configuration is required. Keep the external formatter pointed at `formatter/format-dbeaver.ps1` and use `Ctrl + Shift + F` on a complete SPARQL query or update request.
