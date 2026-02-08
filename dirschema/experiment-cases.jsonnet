// Generates dirschema spec for experiment case directories
// Usage: jsonnet --ext-code "manifest=$(cat manifest.json)" experiment-cases.jsonnet

local manifest = std.extVar('manifest');

assert std.isObject(manifest.cases) : 'manifest.cases must be an object';

// Parse "dir/pattern" into {dir: "dir/", pattern: "pattern"}
// e.g., "instances/*.json" -> {dir: "instances/", pattern: "*.json"}
local parseGlob(path) =
  local parts = std.split(path, '/');
  local dir = std.join('/', parts[0:std.length(parts)-1]) + '/';
  local pattern = parts[std.length(parts)-1];
  { dir: dir, pattern: pattern };

// Generate instance file spec for a case
local instanceSpec(caseSpec) =
  if caseSpec.instance_valid == null then
    []  // No instance validation needed
  else if std.objectHas(caseSpec, 'instances') then
    // Has glob pattern like "instances/*.json"
    local parsed = parseGlob(caseSpec.instances);
    [{ [parsed.dir]: [parsed.pattern] }]
  else
    // Default: single instance.json file
    ["instance.json"];

// Note: We don't check for manifest file here since the manifest content
// is passed as input (jsonnet extVar). The caller already loaded it.
{ "cases/": [
    {
      [caseName + "/"]:
        ["schema.json"] + instanceSpec(manifest.cases[caseName])
    }
    for caseName in std.objectFields(manifest.cases)
  ]
}
