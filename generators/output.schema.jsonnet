{
  title: 'OutputRecord',
  description: 'Captured stdout/stderr from a single correctness check',
  type: 'object',
  required: ['job_id', 'tool'],
  properties: {
    job_id: {
      type: 'string',
      description: 'Stable job hash (sha256 of canonical job dimensions)',
    },
    tool: {
      type: 'string',
      description: 'Tool adapter name',
    },
    stdout: {
      type: 'string',
      description: 'Captured stdout from adapter (omitted when empty)',
    },
    stderr: {
      type: 'string',
      description: 'Captured stderr from adapter (omitted when empty)',
    },
  },
  additionalProperties: false,
}
