# SPARQL support

The same DBeaver external formatter command can format SPARQL as well as the supported SQL dialects:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Path\To\dbeaver-sql-formatter\format-sql.ps1"
```

`format-sql.ps1` detects strong SPARQL syntax signals and routes the selected text to `format-sparql.ps1`. The SPARQL path is isolated from the SQL polish passes so RDF graph syntax is never treated as SQL.

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
- the repository-wide configurable 120-column margin

## Formatting philosophy

SPARQL graph patterns are formatted recursively using the same general philosophy as nested SQL queries: format the inner structure first, then place it at the correct indentation. Braces increase indentation by two spaces. Triple-pattern terminators reset continuation indentation, while predicate-list semicolons continue the next predicate at an additional two spaces.

Keywords are uppercased, while IRIs, prefixed names, variables, RDF literals, and the SPARQL/Turtle shorthand predicate `a` are preserved.

## DBeaver

No second formatter configuration is required. Keep the existing external formatter command and use `Ctrl + Shift + F` on a complete SPARQL query or update request.