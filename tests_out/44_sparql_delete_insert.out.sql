PREFIX ex: <http://example.com/>
WITH <http://example.com/graph>
DELETE {
  ?s ex:old ?old .
}
INSERT {
  ?s ex:new ?new .
}
USING <http://example.com/source>
WHERE {
  ?s ex:old ?old .
  BIND (UCASE (STR (?old)) AS ?new)
}