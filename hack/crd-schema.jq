# Turns a CustomResourceDefinition into one JSON Schema per served version, in
# the shape kubeconform expects, and makes each schema strict.
#
# "Strict" means: wherever the CRD declares the properties of an object, any
# other property is an error. That is what catches a misspelled field. Objects
# the CRD leaves open (x-kubernetes-preserve-unknown-fields, maps, metadata)
# stay open.
#
# Output: one compact JSON object per line:
#   {"group": ..., "kind": ..., "version": ..., "schema": {...}}

def strict:
  if type != "object" then .
  else
    (if has("properties") then .properties |= map_values(strict) else . end)
    | (if has("items") then .items |= (if type == "array" then map(strict) else strict end) else . end)
    | (if (.additionalProperties | type) == "object" then .additionalProperties |= strict else . end)
    | reduce ("allOf", "anyOf", "oneOf") as $key (.; if has($key) then .[$key] |= map(strict) else . end)
    | if has("properties")
         and (has("additionalProperties") | not)
         and (.["x-kubernetes-preserve-unknown-fields"] != true)
      then .additionalProperties = false
      else .
      end
  end;

select(.kind == "CustomResourceDefinition")
| .spec as $spec
| $spec.versions[]
| select(.schema.openAPIV3Schema != null)
| {
    group: $spec.group,
    kind: ($spec.names.kind | ascii_downcase),
    version: .name,
    schema: (.schema.openAPIV3Schema | strict)
  }
