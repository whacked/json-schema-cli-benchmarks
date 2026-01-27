{
  type: 'object',
  properties: {
    name: {
      type: 'string',
    },
    version: {
      type: 'string',
      enum: ['draft-01', 'draft-02'],
    },
    someNumber: {
      type: 'number',
    },
  },
  required: ['name', 'version'],
}
