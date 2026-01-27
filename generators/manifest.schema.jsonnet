{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://github.com/whacked/json-schema-cli-benchmark/schemas/manifest.schema.json",
  "title": "Experiment Manifest",
  "description": "Declares test cases and expected outcomes for a JSON Schema draft benchmark experiment",
  "type": "object",
  "required": ["draft", "cases"],
  "additionalProperties": false,
  "properties": {
    "draft": {
      "type": "string",
      "description": "JSON Schema draft identifier",
      "enum": [
        "draft-04",
        "draft-06",
        "draft-07",
        "draft-2019-09",
        "draft-2020-12"
      ]
    },
    "cases": {
      "type": "object",
      "description": "Mapping from case_id to case specification",
      "additionalProperties": {
        "$ref": "#/$defs/CaseSpec"
      }
    }
  },
  "$defs": {
    "CaseSpec": {
      "type": "object",
      "description": "Specification for a single test case",
      "required": ["schema_valid", "instance_valid"],
      "additionalProperties": false,
      "properties": {
        "schema_valid": {
          "type": "boolean",
          "description": "Expected result of schema validation against metaschema"
        },
        "instance_valid": {
          "type": ["boolean", "null"],
          "description": "Expected result of instance validation, or null if not applicable (when schema_valid is false)"
        },
        "instances": {
          "type": "string",
          "description": "Glob pattern for instance files relative to case directory (e.g. 'instances/**/*.json')"
        },
        "description": {
          "type": "string",
          "description": "Human-readable description of the test case"
        },
        "meta": {
          "type": "object",
          "description": "Arbitrary metadata for reporting/filtering",
          "additionalProperties": true
        }
      }
    }
  }
}
