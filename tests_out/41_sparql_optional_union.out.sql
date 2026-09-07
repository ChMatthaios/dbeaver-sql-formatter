PREFIX foaf: <http://xmlns.com/foaf/0.1/>
SELECT DISTINCT ?person ?label
WHERE {
  ?person a foaf:Person .
  OPTIONAL {
    ?person foaf:name ?label .
  }
  {
    ?person foaf:knows ?friend .
  } UNION {
    ?person foaf:member ?friend .
  }
}
ORDER BY LCASE (?label)
OFFSET 10
LIMIT 20