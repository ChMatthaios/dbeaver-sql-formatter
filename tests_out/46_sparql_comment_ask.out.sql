# Check whether Alice knows a person
PREFIX ex: <http://example.com/>
ASK
WHERE {
  ex:alice ex:knows ?friend .
  FILTER EXISTS {
    ?friend a ex:Person .
  }
}
