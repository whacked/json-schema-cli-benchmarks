// Generates manifest.json for a new experiment
// Usage: jsonnet --ext-str draft=draft-07 manifest.template.jsonnet

local draft = std.extVar('draft');

local validDrafts = ['draft-04', 'draft-06', 'draft-07', 'draft-2019-09', 'draft-2020-12'];

assert std.member(validDrafts, draft) : 'Unknown draft: %s. Valid: %s' % [draft, validDrafts];

{
  draft: draft,
  cases: {
    // Add cases here:
    // "my-case": { "schema_valid": true, "instance_valid": true }
  },
}
