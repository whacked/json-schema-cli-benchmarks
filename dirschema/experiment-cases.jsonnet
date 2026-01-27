// Generates dirschema spec for experiment case directories
// Usage: jsonnet --ext-code "manifest=$(cat manifest.json)" experiment-cases.jsonnet

local manifest = std.extVar('manifest');

assert std.isObject(manifest.cases) : 'manifest.cases must be an object';

[
  "manifest.json",
  { "cases/": [
      {
        [caseName + "/"]:
          ["schema.json"] +
          (if manifest.cases[caseName].instance_valid != null
           then ["instance.json"]
           else [])
      }
      for caseName in std.objectFields(manifest.cases)
    ]
  },
]
