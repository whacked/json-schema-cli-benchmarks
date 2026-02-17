{
  title: 'hyperfine output schema',
  type: 'object',
  required: ['results'],
  properties: {
    results: {
      type: 'array',
      items: {
        type: 'object',
        required: [
          'command',
          'mean',
          'stddev',
          'median',
          'user',
          'system',
          'min',
          'max',
          'times',
          'exit_codes',
          // 'memory_usage_byte',
        ],
        properties: {
          command: { type: 'string' },
          mean: { type: 'number' },
          stddev: { type: 'number' },
          median: { type: 'number' },
          user: { type: 'number' },
          system: { type: 'number' },
          min: { type: 'number' },
          max: { type: 'number' },
          times: {
            type: 'array',
            items: { type: 'number' },
          },
          exit_codes: {
            type: 'array',
            items: { type: 'integer' },
          },
          memory_usage_byte: {
            type: 'array',
            items: { type: 'integer' },
          },
        },
      },
    },
  },
}
