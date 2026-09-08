PREFIX ex: <http://example.com/>
SELECT ?s ?score
WHERE {
  VALUES (?kind ?weight) {
    (ex:Person 10) (ex:Org 20)
  }
  ?s a ?kind .
  BIND (?weight * 2 AS ?score)
  FILTER (?score >= 20 && ?score < 100)
}
ORDER BY DESC (?score)
