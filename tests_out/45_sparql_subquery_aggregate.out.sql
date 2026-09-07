PREFIX ex: <http://example.com/>
SELECT ?s (COUNT (?o) AS ?count)
WHERE {
  {
    SELECT ?s ?o
    WHERE {
      ?s ex:p ?o .
      FILTER (?o != ex:ignored)
    }
  }
}
GROUP BY ?s
HAVING (COUNT (?o) > 1)
