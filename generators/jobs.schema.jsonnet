local hyperfineSchema = (import 'hyperfine.schema.jsonnet');
local hyperfineSingleItem = hyperfineSchema.properties.results.items.properties;

{
  title: 'JobRecord',
  type: 'object',
  required: hyperfineSchema.properties.results.items.required + [
    'job_id',
  ],
  properties: (
    hyperfineSingleItem
  ) {
    job_id: {
      type: 'string',
    },
  },
}
