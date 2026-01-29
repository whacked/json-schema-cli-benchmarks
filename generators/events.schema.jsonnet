{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://github.com/whacked/json-schema-cli-benchmark/schemas/events.schema.json",
  "title": "Benchmark Event",
  "description": "Event record for benchmark runs (append-only events.jsonl)",

  "oneOf": [
    { "$ref": "#/$defs/CorrectnessResult" },
    { "$ref": "#/$defs/BenchmarkResult" }
  ],

  "$defs": {
    "EventEnvelope": {
      "type": "object",
      "description": "Common fields for all events",
      "properties": {
        "event": {
          "type": "string",
          "description": "Event type discriminator"
        },
        "ts": {
          "type": "string",
          "format": "date-time",
          "description": "ISO-8601 timestamp"
        },
        "draft": {
          "type": "string",
          "description": "JSON Schema draft identifier"
        },
        "tool": {
          "type": "string",
          "description": "Tool adapter name"
        },
        "tool_version": {
          "type": "string",
          "description": "Observed tool version string"
        },
        "case_id": {
          "type": "string",
          "description": "Case identifier from manifest"
        },
        "operation": {
          "type": "string",
          "enum": ["schema", "instance"],
          "description": "Operation type: schema validation or instance validation"
        },
        "mode": {
          "type": "string",
          "enum": ["file", "stdin"],
          "description": "Input mode for the operation"
        },
        "job_id": {
          "type": "string",
          "description": "Stable job hash (sha256 of canonical job dimensions)"
        },
        "input_id": {
          "type": ["string", "null"],
          "description": "Relative path of instance file (for instance operations only)"
        },
        "status": {
          "type": "string",
          "enum": ["ok", "unsupported", "error"],
          "description": "Execution status"
        },
        "schema_bytes": {
          "type": "integer",
          "minimum": 0,
          "description": "Size of schema file in bytes"
        },
        "instance_bytes": {
          "type": ["integer", "null"],
          "minimum": 0,
          "description": "Size of instance file in bytes (null for schema-only operations)"
        }
      },
      "required": ["event", "ts", "draft", "tool", "tool_version", "case_id", "operation", "mode", "job_id", "status", "schema_bytes"]
    },

    "CorrectnessResult": {
      "allOf": [
        { "$ref": "#/$defs/EventEnvelope" },
        {
          "type": "object",
          "properties": {
            "event": { "const": "correctness_result" },
            "exit_code": {
              "type": "integer",
              "description": "Raw exit code from adapter"
            },
            "outcome": {
              "type": "string",
              "enum": ["VALID", "INVALID", "UNSUPPORTED", "ERROR"],
              "description": "Interpreted validation outcome"
            },
            "expected": {
              "type": "boolean",
              "description": "Expected validity from manifest"
            },
            "match": {
              "type": "boolean",
              "description": "Did outcome match expected?"
            },
            "stdout_path": {
              "type": ["string", "null"],
              "description": "Path to captured stdout"
            },
            "stderr_path": {
              "type": ["string", "null"],
              "description": "Path to captured stderr"
            }
          },
          "required": ["exit_code", "outcome", "expected", "match"]
        }
      ]
    },

    "BenchmarkResult": {
      "allOf": [
        { "$ref": "#/$defs/EventEnvelope" },
        {
          "type": "object",
          "properties": {
            "event": { "const": "benchmark_result" },
            "mean_s": {
              "type": "number",
              "description": "Mean execution time in seconds"
            },
            "stddev_s": {
              "type": "number",
              "description": "Standard deviation in seconds"
            },
            "min_s": {
              "type": "number",
              "description": "Minimum execution time in seconds"
            },
            "max_s": {
              "type": "number",
              "description": "Maximum execution time in seconds"
            },
            "runs": {
              "type": "integer",
              "minimum": 1,
              "description": "Number of benchmark runs"
            },
            "hyperfine_json_path": {
              "type": ["string", "null"],
              "description": "Path to raw hyperfine JSON output"
            }
          },
          "required": ["mean_s", "stddev_s", "min_s", "max_s", "runs"]
        }
      ]
    }
  }
}
