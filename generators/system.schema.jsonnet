{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://github.com/whacked/json-schema-cli-benchmark/schemas/system.schema.json",
  "title": "System Information",
  "description": "System and environment information captured at benchmark run start",
  "type": "object",
  "properties": {
    "hostname": {
      "type": "string",
      "description": "Machine hostname"
    },
    "platform": {
      "type": "string",
      "description": "OS platform (darwin, linux, win32)"
    },
    "platform_version": {
      "type": "string",
      "description": "OS version string"
    },
    "architecture": {
      "type": "string",
      "description": "CPU architecture (x86_64, arm64)"
    },
    "cpu_model": {
      "type": ["string", "null"],
      "description": "CPU model name (if available)"
    },
    "cpu_cores": {
      "type": ["integer", "null"],
      "minimum": 1,
      "description": "Number of CPU cores (if available)"
    },
    "ram_bytes": {
      "type": ["integer", "null"],
      "minimum": 0,
      "description": "Total RAM in bytes (if available)"
    },
    "python_version": {
      "type": "string",
      "description": "Python version string"
    },
    "run_id": {
      "type": "string",
      "format": "date-time",
      "description": "ISO-8601 timestamp marking the start of this benchmark run"
    },
    "git_sha": {
      "type": ["string", "null"],
      "description": "Git commit SHA of the benchmark repo (if available)"
    },
    "git_dirty": {
      "type": ["boolean", "null"],
      "description": "Whether the git working tree has uncommitted changes"
    },
    "command": {
      "type": "string",
      "description": "Full command line used to invoke this benchmark run"
    }
  },
  "required": [
    "hostname",
    "platform",
    "platform_version",
    "architecture",
    "python_version",
    "run_id",
    "command"
  ],
  "additionalProperties": false
}
