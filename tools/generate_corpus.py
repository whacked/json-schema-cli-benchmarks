#!/usr/bin/env python3
"""
Generate JSON Schema benchmark corpus for multiple drafts.

Creates:
- Valid schemas (tier-specific where needed)
- Invalid schema variants
- Valid instances via jsf
- Invalid instances via deterministic mutation

Output structure (fits existing experiments/ framework):
  experiments/<draft>/
  ├── manifest.yaml
  └── cases/
      ├── <family>_<tier>_valid/
      │   ├── schema.json
      │   └── instances/*.json
      ├── <family>_<tier>_invalid/
      │   ├── schema.json
      │   └── instances/*.json
      └── <family>_schema_<variant>/
          └── schema.json

Supported drafts: draft-04, draft-06, draft-07, 2019-09, 2020-12
"""

import argparse
import copy
import json
import random
import re
import sys
import yaml
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Any, Callable

# jsf is provided by nix-shell (see shell.nix)
from jsf import JSF

# -----------------------------------------------------------------------------
# Tier knobs
# -----------------------------------------------------------------------------

@dataclass(frozen=True)
class TierKnobs:
    """Configuration knobs that control schema/instance size for a tier.

    Primary knobs (P, D, N, L, U, E, T, R) control basic dimensions.
    Derived knobs control schema-specific scaling for particular families.

    When adding a new tier, ALL fields must be specified - this ensures
    no KeyError surprises at runtime from missing tier entries.
    """
    # Primary knobs - control basic dimensions
    P: int  # object width (properties)
    D: int  # nesting depth
    N: int  # array length
    L: int  # string length
    U: int  # oneOf branch count
    E: int  # enum size
    T: int  # tuple width
    R: int  # ref chain length

    # Derived knobs - schema-family-specific scaling
    # These were previously scattered as inline dicts, causing missing key errors
    array_objects_width: int      # width of objects in array_objects schema
    allof_terms: int              # number of terms in combinators_allOf schema
    dependencies_count: int       # number of dependency pairs in dependencies schema
    pattern_properties_count: int # number of patterns in patternProperties schema


TIER_KNOBS = {
    "S": TierKnobs(
        P=16,
        D=4,
        N=32,
        L=32,
        U=4,
        E=64,
        T=8,
        R=4,
        # Derived
        array_objects_width=4,
        allof_terms=3,
        dependencies_count=2,
        pattern_properties_count=2,
    ),
    "M": TierKnobs(
        P=128,
        D=16,
        N=1024,
        L=1024,
        U=16,
        E=4096,
        T=32,
        R=16,
        # Derived
        array_objects_width=8,
        allof_terms=8,
        dependencies_count=8,
        pattern_properties_count=4,
    ),
    "L": TierKnobs(
        P=256,
        D=32,
        N=4096,
        L=4096,
        U=32,
        E=8192,
        T=64,
        R=32,
        # Derived
        array_objects_width=16,
        allof_terms=16,
        dependencies_count=32,
        pattern_properties_count=8,
    ),
    "XL": TierKnobs(
        # Primary: ~2x L (depth/ref grow slower to avoid stack issues)
        P=512,
        D=48,
        N=8192,
        L=8192,
        U=64,
        E=16384,
        T=128,
        R=48,
        # Derived: 2x L
        array_objects_width=32,
        allof_terms=32,
        dependencies_count=64,
        pattern_properties_count=16,
    ),
}

# Draft-specific $schema URIs
DRAFT_SCHEMAS = {
    "draft-04": "http://json-schema.org/draft-04/schema#",
    "draft-06": "http://json-schema.org/draft-06/schema#",
    "draft-07": "http://json-schema.org/draft-07/schema#",
    "2019-09": "https://json-schema.org/draft/2019-09/schema",
    "2020-12": "https://json-schema.org/draft/2020-12/schema",
}

# Draft feature support
# - dependencies: draft-04, draft-06, draft-07 (replaced by dependentRequired in 2019-09+)
# - additionalItems: draft-04, draft-06, draft-07 (replaced by prefixItems/items in 2020-12)


def get_schema_uri(draft: str) -> str:
    """Get $schema URI for a draft."""
    if draft not in DRAFT_SCHEMAS:
        raise ValueError(f"Unsupported draft: {draft}. Supported: {list(DRAFT_SCHEMAS.keys())}")
    return DRAFT_SCHEMAS[draft]


def uses_dependencies(draft: str) -> bool:
    """Return True if draft uses 'dependencies' keyword (vs dependentRequired)."""
    return draft in ("draft-04", "draft-06", "draft-07")


def uses_additional_items(draft: str) -> bool:
    """Return True if draft uses 'additionalItems' keyword (vs prefixItems/items)."""
    return draft in ("draft-04", "draft-06", "draft-07", "2019-09")

# -----------------------------------------------------------------------------
# JSON writing helper
# -----------------------------------------------------------------------------

def write_json(path: Path, data: Any) -> None:
    """Write JSON with stable formatting."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")


def write_manifest(path: Path, data: Any) -> None:
    """Write manifest as JSON or YAML."""
    if path.suffix.lower().endswith("json"):
        write_json(path, data)
    else:
        with open(path, "w") as f:
            yaml.safe_dump(data, f)


# -----------------------------------------------------------------------------
# Instance mutation primitives
# -----------------------------------------------------------------------------

def delete_required_key(obj: dict, key: str) -> dict:
    """Delete a key from object."""
    result = copy.deepcopy(obj)
    if key in result:
        del result[key]
    return result


def add_extra_key(obj: dict, key: str = "__extra", value: Any = 1) -> dict:
    """Add an extra key to object."""
    result = copy.deepcopy(obj)
    result[key] = value
    return result


def flip_type(value: Any) -> Any:
    """Flip value to a different type."""
    if isinstance(value, bool):
        return "true"  # bool -> string
    elif isinstance(value, int):
        return str(value)  # int -> string
    elif isinstance(value, str):
        return 12345  # string -> int
    elif isinstance(value, list):
        return {"was": "array"}  # array -> object
    elif isinstance(value, dict):
        return ["was", "object"]  # object -> array
    else:
        return "corrupted"


def convert_tuples_to_lists(obj: Any) -> Any:
    """Recursively convert tuples to lists for JSON compatibility."""
    if isinstance(obj, tuple):
        return [convert_tuples_to_lists(x) for x in obj]
    elif isinstance(obj, list):
        return [convert_tuples_to_lists(x) for x in obj]
    elif isinstance(obj, dict):
        return {k: convert_tuples_to_lists(v) for k, v in obj.items()}
    return obj


def corrupt_value_at_path(obj: Any, path: list[str | int]) -> Any:
    """Corrupt value at given path."""
    if not path:
        return flip_type(obj)

    # Convert tuples to lists for mutability
    result = convert_tuples_to_lists(copy.deepcopy(obj))
    current = result
    for key in path[:-1]:
        current = current[key]

    last_key = path[-1]
    current[last_key] = flip_type(current[last_key])
    return result


def find_deepest_leaf_path(obj: Any, current_path: list = None) -> list:
    """Find path to deepest leaf value."""
    if current_path is None:
        current_path = []

    if isinstance(obj, dict) and obj:
        deepest = current_path
        for key, value in obj.items():
            candidate = find_deepest_leaf_path(value, current_path + [key])
            if len(candidate) > len(deepest):
                deepest = candidate
        return deepest
    elif isinstance(obj, (list, tuple)) and obj:
        deepest = current_path
        for i, value in enumerate(obj):
            candidate = find_deepest_leaf_path(value, current_path + [i])
            if len(candidate) > len(deepest):
                deepest = candidate
        return deepest
    else:
        return current_path


def duplicate_array_element(arr: list) -> list:
    """Duplicate an element in array (for uniqueItems violation)."""
    if len(arr) < 2:
        return arr + arr  # Just duplicate the whole thing
    result = copy.deepcopy(arr)
    result.append(copy.deepcopy(result[0]))
    return result


# -----------------------------------------------------------------------------
# Schema generators
# -----------------------------------------------------------------------------

def schema_object_basic(knobs: dict, draft: str) -> dict:
    """Baseline object with properties/required/additionalProperties."""
    return {
        "$schema": get_schema_uri(draft),
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "id": {"type": "integer"},
            "name": {"type": "string", "minLength": 1, "maxLength": knobs.L},
            "active": {"type": "boolean"},
        },
        "required": ["id", "name"],
    }


def schema_object_deep(knobs: dict, draft: str) -> dict:
    """Nested object chain of depth D."""
    depth = knobs.D

    # Build from leaf up
    leaf = {
        "type": "object",
        "properties": {"value": {"type": "integer"}},
        "required": ["value"],
    }

    current = leaf
    for _ in range(depth - 1):
        current = {
            "type": "object",
            "properties": {
                "next": current,
                "value": {"type": "integer"},
            },
            "required": ["next"],
        }

    return {
        "$schema": get_schema_uri(draft),
        **current,
    }


def schema_object_wide(knobs: dict, draft: str) -> dict:
    """Object with P properties."""
    P = knobs.P
    properties = {f"k{i:04d}": {"type": "integer"} for i in range(P)}
    required = [f"k{i:04d}" for i in range(P // 4)]

    return {
        "$schema": get_schema_uri(draft),
        "type": "object",
        "additionalProperties": False,
        "properties": properties,
        "required": required,
    }


def schema_array_primitives(knobs: dict, draft: str) -> dict:
    """Array of N integers."""
    N = knobs.N
    return {
        "$schema": get_schema_uri(draft),
        "type": "array",
        "minItems": N,
        "maxItems": N,
        "items": {"type": "integer"},
    }


def schema_array_objects(knobs: TierKnobs, draft: str) -> dict:
    """Array of N objects with small width."""
    N = knobs.N
    obj_width = knobs.array_objects_width

    properties = {f"f{i}": {"type": "integer"} for i in range(obj_width)}
    required = list(properties.keys())

    return {
        "$schema": get_schema_uri(draft),
        "type": "array",
        "minItems": N,
        "maxItems": N,
        "items": {
            "type": "object",
            "additionalProperties": False,
            "properties": properties,
            "required": required,
        },
    }


def schema_array_tuple(knobs: dict, draft: str) -> dict:
    """Tuple array with T items."""
    T = knobs.T
    type_cycle = ["integer", "string", "boolean"]
    tuple_items = [{"type": type_cycle[i % len(type_cycle)]} for i in range(T)]

    schema = {
        "$schema": get_schema_uri(draft),
        "type": "array",
    }

    if uses_additional_items(draft):
        # draft-04, draft-06, draft-07, 2019-09: use items array + additionalItems
        schema["items"] = tuple_items
        schema["additionalItems"] = False
    else:
        # 2020-12: use prefixItems + items: false
        schema["prefixItems"] = tuple_items
        schema["items"] = False

    return schema


def schema_combinators_oneOf(knobs: dict, draft: str) -> dict:
    """oneOf with U discriminated branches."""
    U = knobs.U
    branches = []
    for i in range(U):
        branches.append({
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "kind": {"enum": [f"k{i:02d}"]},
                "v": {"type": "integer"},
            },
            "required": ["kind", "v"],
        })

    return {
        "$schema": get_schema_uri(draft),
        "oneOf": branches,
    }


def schema_combinators_allOf(knobs: TierKnobs, draft: str) -> dict:
    """allOf with multiple constraints."""
    count = knobs.allof_terms

    terms = []
    for i in range(count):
        terms.append({
            "type": "object",
            "properties": {f"p{i}": {"type": "integer"}},
            "required": [f"p{i}"],
        })

    return {
        "$schema": get_schema_uri(draft),
        "allOf": terms,
    }


def schema_ref_graph(knobs: dict, draft: str) -> dict:
    """$ref chain with shared definitions."""
    R = knobs.R

    # 2019-09+ uses $defs instead of definitions
    defs_key = "$defs" if draft in ("2019-09", "2020-12") else "definitions"
    defs_ref = "#/$defs" if draft in ("2019-09", "2020-12") else "#/definitions"

    definitions = {
        "shared": {
            "type": "object",
            "properties": {"x": {"type": "integer"}},
            "required": ["x"],
        }
    }

    # Build chain from end to start
    for i in range(R - 1, -1, -1):
        if i == R - 1:
            # Leaf node
            definitions[f"node{i}"] = {
                "allOf": [
                    {"$ref": f"{defs_ref}/shared"},
                    {
                        "type": "object",
                        "properties": {"value": {"type": "integer"}},
                        "required": ["value"],
                    },
                ]
            }
        else:
            # Chain node
            definitions[f"node{i}"] = {
                "allOf": [
                    {"$ref": f"{defs_ref}/shared"},
                    {
                        "type": "object",
                        "properties": {"next": {"$ref": f"{defs_ref}/node{i+1}"}},
                        "required": ["next"],
                    },
                ]
            }

    return {
        "$schema": get_schema_uri(draft),
        "$ref": f"{defs_ref}/node0",
        defs_key: definitions,
    }


def schema_dependencies(knobs: TierKnobs, draft: str) -> dict:
    """dependencies keyword (or dependentRequired in 2019-09+)."""
    count = knobs.dependencies_count

    properties = {
        "base": {"type": "string"},
    }
    deps = {}

    for i in range(count):
        prop = f"field{i}"
        dep = f"dep{i}"
        properties[prop] = {"type": "string"}
        properties[dep] = {"type": "string"}
        deps[prop] = [dep]

    schema = {
        "$schema": get_schema_uri(draft),
        "type": "object",
        "properties": properties,
    }

    # Use appropriate keyword for draft
    if uses_dependencies(draft):
        schema["dependencies"] = deps
    else:
        schema["dependentRequired"] = deps

    return schema


def schema_patternProperties(knobs: TierKnobs, draft: str) -> dict:
    """patternProperties with multiple patterns."""
    count = knobs.pattern_properties_count

    patterns = {}
    for i in range(count):
        patterns[f"^p{i}_[a-z]+$"] = {"type": "integer"}

    return {
        "$schema": get_schema_uri(draft),
        "type": "object",
        "patternProperties": patterns,
        "additionalProperties": False,
    }


def schema_enum_uniqueItems(knobs: dict, draft: str) -> dict:
    """enum and uniqueItems."""
    E = knobs.E
    N = min(knobs.N, 1000)  # Cap array size for uniqueItems

    enum_values = [f"v{i:06d}" for i in range(E)]

    return {
        "$schema": get_schema_uri(draft),
        "type": "object",
        "properties": {
            "tag": {"enum": enum_values},
            "xs": {
                "type": "array",
                "minItems": N,
                "maxItems": N,
                "items": {"type": "integer"},
                "uniqueItems": True,
            },
        },
        "required": ["tag", "xs"],
        "additionalProperties": False,
    }


# -----------------------------------------------------------------------------
# Invalid schema generators
# -----------------------------------------------------------------------------

def invalid_schema_bad_type_keyword(schema: dict) -> dict:
    """Set type to invalid value."""
    result = copy.deepcopy(schema)
    # Find first 'type' and corrupt it
    def corrupt_type(obj):
        if isinstance(obj, dict):
            if "type" in obj:
                obj["type"] = 123
                return True
            for v in obj.values():
                if corrupt_type(v):
                    return True
        elif isinstance(obj, list):
            for item in obj:
                if corrupt_type(item):
                    return True
        return False
    corrupt_type(result)
    return result


def invalid_schema_bad_regex(schema: dict) -> dict:
    """Inject invalid regex pattern."""
    result = copy.deepcopy(schema)
    # Find a string property and add bad pattern
    def add_bad_pattern(obj):
        if isinstance(obj, dict):
            if obj.get("type") == "string":
                obj["pattern"] = "*("
                return True
            for v in obj.values():
                if add_bad_pattern(v):
                    return True
        elif isinstance(obj, list):
            for item in obj:
                if add_bad_pattern(item):
                    return True
        return False
    if not add_bad_pattern(result):
        # Fallback: add pattern at root
        result["pattern"] = "*("
    return result


def invalid_schema_required_not_array(schema: dict) -> dict:
    """Set required to non-array."""
    result = copy.deepcopy(schema)
    def corrupt_required(obj):
        if isinstance(obj, dict):
            if "required" in obj:
                obj["required"] = "id"
                return True
            for v in obj.values():
                if corrupt_required(v):
                    return True
        elif isinstance(obj, list):
            for item in obj:
                if corrupt_required(item):
                    return True
        return False
    corrupt_required(result)
    return result


def invalid_schema_properties_not_object(schema: dict) -> dict:
    """Set properties to non-object."""
    result = copy.deepcopy(schema)
    if "properties" in result:
        result["properties"] = []
    return result


def invalid_schema_minitems_string(schema: dict) -> dict:
    """Set minItems to string."""
    result = copy.deepcopy(schema)
    def corrupt_minitems(obj):
        if isinstance(obj, dict):
            if "minItems" in obj:
                obj["minItems"] = "10"
                return True
            for v in obj.values():
                if corrupt_minitems(v):
                    return True
        elif isinstance(obj, list):
            for item in obj:
                if corrupt_minitems(item):
                    return True
        return False
    corrupt_minitems(result)
    return result


def invalid_schema_items_not_schema(schema: dict) -> dict:
    """Set items to non-schema value."""
    result = copy.deepcopy(schema)
    if "items" in result:
        result["items"] = 5
    return result


def invalid_schema_additionalItems_wrong_type(schema: dict, draft: str = "draft-04") -> dict:
    """Set additionalItems/items to wrong type (draft-dependent)."""
    result = copy.deepcopy(schema)
    if uses_additional_items(draft):
        if "additionalItems" in result:
            result["additionalItems"] = "nope"
    else:
        # 2020-12: items (boolean) should be corrupted
        if "items" in result:
            result["items"] = "nope"
    return result


def invalid_schema_oneOf_not_array(schema: dict) -> dict:
    """Set oneOf to non-array."""
    result = copy.deepcopy(schema)
    if "oneOf" in result:
        result["oneOf"] = {}
    return result


def invalid_schema_allOf_scalar(schema: dict) -> dict:
    """Set allOf to scalar."""
    result = copy.deepcopy(schema)
    if "allOf" in result:
        result["allOf"] = 1
    return result


def invalid_schema_bad_type_in_def(schema: dict, draft: str = "draft-04") -> dict:
    """Set type to invalid value in a definition (fails metaschema)."""
    result = copy.deepcopy(schema)
    # Find first definition and corrupt its type
    defs_key = "$defs" if draft in ("2019-09", "2020-12") else "definitions"
    if defs_key in result:
        for key in result[defs_key]:
            def_schema = result[defs_key][key]
            if "type" in def_schema:
                def_schema["type"] = 123
                break
            elif "allOf" in def_schema:
                for term in def_schema["allOf"]:
                    if "type" in term:
                        term["type"] = 123
                        break
                break
    return result


def invalid_schema_dependencies_wrong_type(schema: dict, draft: str = "draft-04") -> dict:
    """Set dependencies/dependentRequired to wrong type."""
    result = copy.deepcopy(schema)
    if uses_dependencies(draft):
        if "dependencies" in result:
            result["dependencies"] = []
    else:
        if "dependentRequired" in result:
            result["dependentRequired"] = []
    return result


def invalid_schema_patternProperties_not_object(schema: dict) -> dict:
    """Set patternProperties to non-object."""
    result = copy.deepcopy(schema)
    if "patternProperties" in result:
        result["patternProperties"] = []
    return result


def invalid_schema_enum_not_array(schema: dict) -> dict:
    """Set enum to non-array."""
    result = copy.deepcopy(schema)
    def corrupt_enum(obj):
        if isinstance(obj, dict):
            if "enum" in obj:
                obj["enum"] = "v000001"
                return True
            for v in obj.values():
                if corrupt_enum(v):
                    return True
        elif isinstance(obj, list):
            for item in obj:
                if corrupt_enum(item):
                    return True
        return False
    corrupt_enum(result)
    return result


# -----------------------------------------------------------------------------
# Case family definitions
# -----------------------------------------------------------------------------

@dataclass
class CaseFamily:
    """Definition of a case family."""
    name: str
    description: str
    schema_generator: Callable[[dict], dict]
    invalid_schema_generators: dict[str, Callable[[dict], dict]]
    instance_mutations: list[str] = field(default_factory=lambda: [
        "missing_required",
        "wrong_type_early",
        "extra_property",
    ])


CASE_FAMILIES = [
    CaseFamily(
        name="object_basic",
        description="Baseline object: properties/required/additionalProperties",
        schema_generator=schema_object_basic,
        invalid_schema_generators={
            "bad_type": invalid_schema_bad_type_keyword,
            "bad_regex": invalid_schema_bad_regex,
        },
    ),
    CaseFamily(
        name="object_deep",
        description="Nested object chain for depth traversal",
        schema_generator=schema_object_deep,
        invalid_schema_generators={
            "required_not_array": invalid_schema_required_not_array,
        },
        instance_mutations=["wrong_type_deep", "missing_required"],
    ),
    CaseFamily(
        name="object_wide",
        description="Wide object with many properties",
        schema_generator=schema_object_wide,
        invalid_schema_generators={
            "properties_not_object": invalid_schema_properties_not_object,
        },
    ),
    CaseFamily(
        name="array_primitives",
        description="Array of primitive integers",
        schema_generator=schema_array_primitives,
        invalid_schema_generators={
            "minitems_string": invalid_schema_minitems_string,
        },
        instance_mutations=["wrong_type_early", "wrong_type_late"],
    ),
    CaseFamily(
        name="array_objects",
        description="Array of objects",
        schema_generator=schema_array_objects,
        invalid_schema_generators={
            "items_not_schema": invalid_schema_items_not_schema,
        },
        instance_mutations=["wrong_type_early", "wrong_type_late", "extra_property_nested"],
    ),
    CaseFamily(
        name="array_tuple",
        description="Tuple array with additionalItems:false",
        schema_generator=schema_array_tuple,
        invalid_schema_generators={
            "additionalItems_wrong": invalid_schema_additionalItems_wrong_type,
        },
        instance_mutations=["wrong_type_early", "too_long_tuple"],
    ),
    CaseFamily(
        name="combinators_oneOf",
        description="oneOf with discriminated branches",
        schema_generator=schema_combinators_oneOf,
        invalid_schema_generators={
            "oneOf_not_array": invalid_schema_oneOf_not_array,
        },
        instance_mutations=["oneOf_matches_none", "wrong_type_early"],
    ),
    CaseFamily(
        name="combinators_allOf",
        description="allOf constraint intersection",
        schema_generator=schema_combinators_allOf,
        invalid_schema_generators={
            "allOf_scalar": invalid_schema_allOf_scalar,
        },
        instance_mutations=["missing_required", "wrong_type_early"],
    ),
    CaseFamily(
        name="ref_graph",
        description="$ref chain with shared definitions",
        schema_generator=schema_ref_graph,
        invalid_schema_generators={
            "bad_type_in_def": invalid_schema_bad_type_in_def,
        },
        instance_mutations=["missing_required", "wrong_type_deep"],
    ),
    CaseFamily(
        name="dependencies",
        description="dependencies keyword behavior",
        schema_generator=schema_dependencies,
        invalid_schema_generators={
            "dependencies_wrong": invalid_schema_dependencies_wrong_type,
        },
        instance_mutations=["missing_dependency"],
    ),
    CaseFamily(
        name="patternProperties",
        description="patternProperties with additionalProperties:false",
        schema_generator=schema_patternProperties,
        invalid_schema_generators={
            "patternProperties_not_object": invalid_schema_patternProperties_not_object,
        },
        instance_mutations=["extra_property", "wrong_type_early"],
    ),
    CaseFamily(
        name="enum_uniqueItems",
        description="enum membership and uniqueItems cost",
        schema_generator=schema_enum_uniqueItems,
        invalid_schema_generators={
            "enum_not_array": invalid_schema_enum_not_array,
        },
        instance_mutations=["wrong_enum_value", "duplicate_array_element"],
    ),
]


# -----------------------------------------------------------------------------
# Instance generation
# -----------------------------------------------------------------------------

def generate_valid_instances(schema: dict, n: int, seed: int, family_name: str = "") -> list[dict]:
    """Generate n valid instances from schema using jsf, with fallbacks."""
    random.seed(seed)

    # Special handling for schemas jsf can't handle well
    if family_name == "patternProperties":
        return generate_patternProperties_instances(schema, n, seed)
    elif family_name == "combinators_allOf":
        return generate_allOf_instances(schema, n, seed)
    elif family_name == "ref_graph":
        return generate_ref_graph_instances(schema, n, seed)
    elif family_name == "dependencies":
        return generate_dependencies_instances(schema, n, seed)

    try:
        faker = JSF(schema)
        instances = []
        for i in range(n):
            random.seed(seed + i)
            instance = faker.generate()
            # Convert tuples to lists for JSON compatibility
            instance = convert_tuples_to_lists(instance)
            instances.append(instance)
        return instances
    except Exception as e:
        print(f"Warning: jsf generation failed for {family_name}: {e}", file=sys.stderr)
        return []


def generate_patternProperties_instances(schema: dict, n: int, seed: int) -> list[dict]:
    """Generate instances for patternProperties schemas."""
    random.seed(seed)
    instances = []

    patterns = schema.get("patternProperties", {})
    # Extract pattern prefixes (e.g., "^p0_[a-z]+$" -> "p0_")
    prefixes = []
    for pattern in patterns.keys():
        # Simple extraction: ^prefix_[a-z]+$ -> prefix_
        match = re.match(r'\^([a-z0-9]+_)', pattern)
        if match:
            prefixes.append((match.group(1), patterns[pattern]))

    for i in range(n):
        instance = {}
        # Generate some keys for each pattern
        for prefix, subschema in prefixes:
            n_keys = random.randint(1, 5)
            for j in range(n_keys):
                key = f"{prefix}{''.join(random.choices('abcdefghij', k=4))}"
                if subschema.get("type") == "integer":
                    instance[key] = random.randint(0, 1000)
                elif subschema.get("type") == "boolean":
                    instance[key] = random.choice([True, False])
                else:
                    instance[key] = f"value_{j}"
        instances.append(instance)

    return instances


def generate_allOf_instances(schema: dict, n: int, seed: int) -> list[dict]:
    """Generate instances for allOf schemas - must satisfy all terms."""
    random.seed(seed)
    instances = []

    all_of = schema.get("allOf", [])

    for i in range(n):
        instance = {}
        # Merge all required properties from all allOf terms
        for term in all_of:
            props = term.get("properties", {})
            required = term.get("required", [])
            for key in required:
                if key in props:
                    prop_schema = props[key]
                    if prop_schema.get("type") == "integer":
                        instance[key] = random.randint(0, 10000)
                    elif prop_schema.get("type") == "string":
                        instance[key] = f"value_{key}_{random.randint(0, 100)}"
                    elif prop_schema.get("type") == "boolean":
                        instance[key] = random.choice([True, False])
        instances.append(instance)

    return instances


def generate_ref_graph_instances(schema: dict, n: int, seed: int) -> list[dict]:
    """Generate instances for ref_graph schemas - nested objects with shared 'x' field."""
    random.seed(seed)
    instances = []

    # Count how many nodes in the chain by looking at definitions
    definitions = schema.get("definitions", {})
    node_count = sum(1 for k in definitions.keys() if k.startswith("node"))

    for i in range(n):
        # Build from leaf up
        current = {"x": random.randint(0, 10000), "value": random.randint(0, 10000)}
        for _ in range(node_count - 1):
            current = {"x": random.randint(0, 10000), "next": current}
        instances.append(current)

    return instances


def generate_dependencies_instances(schema: dict, n: int, seed: int) -> list[dict]:
    """Generate instances for dependencies schemas - include deps when field present."""
    random.seed(seed)
    instances = []

    props = schema.get("properties", {})
    deps = schema.get("dependencies", {})

    for i in range(n):
        instance = {}
        # Always include base if present
        if "base" in props:
            instance["base"] = f"base_value_{random.randint(0, 100)}"

        # For each dependency pair, either include both or neither
        for field, dep_list in deps.items():
            if random.choice([True, False]):  # Randomly decide to include this pair
                # Include field and all its dependencies
                if field in props:
                    instance[field] = f"{field}_value_{random.randint(0, 100)}"
                for dep in dep_list:
                    if dep in props:
                        instance[dep] = f"{dep}_value_{random.randint(0, 100)}"

        instances.append(instance)

    return instances


def generate_ref_graph_invalid_instances(valid_instances: list[dict], mutations: list[str],
                                          schema: dict, m: int, seed: int) -> list[tuple[str, dict]]:
    """Generate invalid instances for ref_graph schemas."""
    random.seed(seed)
    invalid = []

    for i in range(m):
        base = copy.deepcopy(valid_instances[i % len(valid_instances)])

        if i % 2 == 0:
            # Remove 'x' from root (required by shared)
            mutation = "missing_x_root"
            if "x" in base:
                del base["x"]
        else:
            # Corrupt type of deepest 'value' or 'x'
            mutation = "wrong_type_deep"
            # Find and corrupt deepest leaf
            current = base
            while "next" in current:
                current = current["next"]
            if "value" in current:
                current["value"] = "not_an_integer"
            elif "x" in current:
                current["x"] = "not_an_integer"

        invalid.append((mutation, base))

    return invalid


def generate_allOf_invalid_instances(valid_instances: list[dict], mutations: list[str],
                                      schema: dict, m: int, seed: int) -> list[tuple[str, dict]]:
    """Generate invalid instances for allOf schemas."""
    random.seed(seed)
    invalid = []

    all_of = schema.get("allOf", [])
    all_required = []
    for term in all_of:
        all_required.extend(term.get("required", []))

    for i in range(m):
        base = copy.deepcopy(valid_instances[i % len(valid_instances)])

        if i % 2 == 0 and all_required:
            # Remove a required field
            mutation = "missing_required"
            key_to_remove = all_required[i % len(all_required)]
            if key_to_remove in base:
                del base[key_to_remove]
        else:
            # Corrupt type of a field
            mutation = "wrong_type"
            for key in base:
                base[key] = "not_an_integer"
                break

        invalid.append((mutation, base))

    return invalid


def mutate_instance(instance: Any, mutation_type: str, schema: dict) -> Any:
    """Apply a mutation to create an invalid instance."""
    if mutation_type == "missing_required":
        if isinstance(instance, dict):
            # Find a required key to delete
            required = schema.get("required", [])
            if required and isinstance(instance, dict):
                key = required[0]
                return delete_required_key(instance, key)
        return instance

    elif mutation_type == "wrong_type_early":
        if isinstance(instance, dict) and instance:
            # Corrupt first key
            first_key = list(instance.keys())[0]
            return corrupt_value_at_path(instance, [first_key])
        elif isinstance(instance, (list, tuple)) and instance:
            # Corrupt first element
            return corrupt_value_at_path(list(instance), [0])
        return flip_type(instance)

    elif mutation_type == "wrong_type_late" or mutation_type == "wrong_type_deep":
        path = find_deepest_leaf_path(instance)
        if path:
            return corrupt_value_at_path(instance, path)
        return flip_type(instance)

    elif mutation_type == "extra_property":
        if isinstance(instance, dict):
            return add_extra_key(instance)
        return instance

    elif mutation_type == "extra_property_nested":
        if isinstance(instance, (list, tuple)) and instance and isinstance(instance[0], dict):
            result = list(copy.deepcopy(instance))
            result[0] = add_extra_key(result[0])
            return result
        return instance

    elif mutation_type == "too_long_tuple":
        if isinstance(instance, (list, tuple)):
            result = list(copy.deepcopy(instance))
            result.append(12345)  # Add extra element
            return result
        return instance

    elif mutation_type == "oneOf_matches_none":
        if isinstance(instance, dict) and "kind" in instance:
            result = copy.deepcopy(instance)
            result["kind"] = "nope"
            return result
        return instance

    elif mutation_type == "missing_dependency":
        # For dependencies case: include field but not its dependency
        if isinstance(instance, dict):
            result = copy.deepcopy(instance)
            # Add a field that has a dependency, remove the dependency
            result["field0"] = "value"
            if "dep0" in result:
                del result["dep0"]
            return result
        return instance

    elif mutation_type == "wrong_enum_value":
        if isinstance(instance, dict) and "tag" in instance:
            result = copy.deepcopy(instance)
            result["tag"] = "not_in_enum"
            return result
        return instance

    elif mutation_type == "duplicate_array_element":
        if isinstance(instance, dict) and "xs" in instance:
            result = copy.deepcopy(instance)
            result["xs"] = duplicate_array_element(result["xs"])
            return result
        return instance

    return instance


def generate_invalid_instances(valid_instances: list[dict], mutations: list[str],
                               schema: dict, m: int, seed: int) -> list[tuple[str, dict]]:
    """Generate m invalid instances by mutating valid ones."""
    random.seed(seed)

    invalid = []
    for i in range(m):
        # Pick a valid instance and mutation type
        base_instance = valid_instances[i % len(valid_instances)] if valid_instances else {}
        mutation = mutations[i % len(mutations)]

        mutated = mutate_instance(base_instance, mutation, schema)
        invalid.append((mutation, mutated))

    return invalid


# -----------------------------------------------------------------------------
# Main generation logic
# -----------------------------------------------------------------------------

def generate_corpus(
    out_dir: Path,
    draft: str = "draft-04",
    seed: int = 0,
    n_valid: int = 20,
    m_invalid: int = 8,
    tiers: list[str] = None,
    families: list[str] = None,
) -> dict:
    """Generate the complete corpus."""

    # Validate draft
    if draft not in DRAFT_SCHEMAS:
        raise ValueError(f"Unsupported draft: {draft}. Supported: {list(DRAFT_SCHEMAS.keys())}")

    if tiers is None:
        tiers = ["S", "M", "L"]

    family_map = {f.name: f for f in CASE_FAMILIES}
    if families is None:
        families = list(family_map.keys())

    cases_dir = out_dir / "cases"
    manifest_cases = {}

    for family_name in families:
        family = family_map[family_name]
        print(f"Generating {family_name}...")

        for tier in tiers:
            knobs = TIER_KNOBS[tier]

            # Generate valid schema (pass draft)
            schema = family.schema_generator(knobs, draft)

            # Generate valid instances
            tier_seed = seed + hash(f"{family_name}_{tier}") % 10000
            valid_instances = generate_valid_instances(schema, n_valid, tier_seed, family_name)

            if not valid_instances:
                print(f"  Warning: No valid instances for {family_name} tier {tier}")
                continue

            # Case: valid schema + valid instances
            case_id_valid = f"{family_name}_{tier}_valid"
            case_dir_valid = cases_dir / case_id_valid

            write_json(case_dir_valid / "schema.json", schema)
            instances_dir_valid = case_dir_valid / "instances"
            for i, instance in enumerate(valid_instances):
                write_json(instances_dir_valid / f"gen_{i:04d}.json", instance)

            manifest_cases[case_id_valid] = {
                "description": f"{family.description} - tier {tier} valid instances",
                "schema_valid": True,
                "instance_valid": True,
                "instances": "instances/*.json",
                "meta": {"family": family_name, "tier": tier, "instance_type": "valid"},
            }

            # Generate invalid instances (use custom generators for complex schemas)
            if family_name == "ref_graph":
                invalid_instances = generate_ref_graph_invalid_instances(
                    valid_instances, family.instance_mutations, schema, m_invalid, tier_seed + 1000
                )
            elif family_name == "combinators_allOf":
                invalid_instances = generate_allOf_invalid_instances(
                    valid_instances, family.instance_mutations, schema, m_invalid, tier_seed + 1000
                )
            else:
                invalid_instances = generate_invalid_instances(
                    valid_instances, family.instance_mutations, schema, m_invalid, tier_seed + 1000
                )

            # Case: valid schema + invalid instances
            case_id_invalid = f"{family_name}_{tier}_invalid"
            case_dir_invalid = cases_dir / case_id_invalid

            write_json(case_dir_invalid / "schema.json", schema)
            instances_dir_invalid = case_dir_invalid / "instances"
            for i, (mutation, instance) in enumerate(invalid_instances):
                write_json(instances_dir_invalid / f"{mutation}_{i:04d}.json", instance)

            manifest_cases[case_id_invalid] = {
                "description": f"{family.description} - tier {tier} invalid instances",
                "schema_valid": True,
                "instance_valid": False,
                "instances": "instances/*.json",
                "meta": {"family": family_name, "tier": tier, "instance_type": "invalid"},
            }

        # Generate invalid schema variants (not tier-specific)
        base_schema = family.schema_generator(TIER_KNOBS["S"], draft)  # Use S tier as base

        for variant_name, generator in family.invalid_schema_generators.items():
            case_id = f"{family_name}_schema_{variant_name}"
            case_dir = cases_dir / case_id

            # Pass draft to generators that need it
            try:
                invalid_schema = generator(base_schema, draft)
            except TypeError:
                # Generator doesn't accept draft parameter
                invalid_schema = generator(base_schema)
            write_json(case_dir / "schema.json", invalid_schema)

            manifest_cases[case_id] = {
                "description": f"{family.description} - invalid schema ({variant_name})",
                "schema_valid": False,
                "instance_valid": None,
                "meta": {"family": family_name, "schema_variant": variant_name},
            }

    # Write manifest
    manifest = {
        "draft": draft,
        "cases": manifest_cases,
    }

    # figure out which file to write to
    manifest_json_path = out_dir / "manifest.json"
    manifest_yaml_path = out_dir / "manifest.yaml"

    if manifest_yaml_path.exists():
        write_manifest(manifest_yaml_path, manifest)
    else:
        write_manifest(manifest_json_path, manifest)

    # Summary
    n_cases = len(manifest_cases)
    n_valid_cases = sum(1 for c in manifest_cases.values() if c["schema_valid"] and c["instance_valid"])
    n_invalid_cases = sum(1 for c in manifest_cases.values() if c["schema_valid"] and not c["instance_valid"])
    n_schema_invalid = sum(1 for c in manifest_cases.values() if not c["schema_valid"])

    print(f"\nGenerated {n_cases} cases:")
    print(f"  - {n_valid_cases} valid schema + valid instances")
    print(f"  - {n_invalid_cases} valid schema + invalid instances")
    print(f"  - {n_schema_invalid} invalid schema cases")

    # Size summary per tier
    print(f"\nSize summary by tier:")
    for tier in tiers:
        tier_cases = [c for c in cases_dir.iterdir() if c.is_dir() and f"_{tier}_" in c.name]
        if not tier_cases:
            continue
        max_schema_size = 0
        max_instance_size = 0
        for case_dir in tier_cases:
            schema_path = case_dir / "schema.json"
            if schema_path.exists():
                max_schema_size = max(max_schema_size, schema_path.stat().st_size)
            instances_dir = case_dir / "instances"
            if instances_dir.exists():
                for inst in instances_dir.iterdir():
                    max_instance_size = max(max_instance_size, inst.stat().st_size)
        print(f"  {tier}: max schema {max_schema_size:,} bytes, max instance {max_instance_size:,} bytes")

    print(f"\nOutput: {out_dir}")

    return manifest


# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Generate JSON Schema benchmark corpus")
    parser.add_argument("--draft", type=str, default="draft-04",
                        choices=list(DRAFT_SCHEMAS.keys()),
                        help=f"JSON Schema draft (default: draft-04, choices: {list(DRAFT_SCHEMAS.keys())})")
    parser.add_argument("--out", type=Path, default=None,
                        help="Output directory (default: experiments/<draft>)")
    parser.add_argument("--seed", type=int, default=0,
                        help="Random seed (default: 0)")
    parser.add_argument("--n-valid", type=int, default=20,
                        help="Number of valid instances per case (default: 20)")
    parser.add_argument("--m-invalid", type=int, default=8,
                        help="Number of invalid instances per case (default: 8)")
    parser.add_argument("--tiers", type=str, default="S,M,L",
                        help="Comma-separated tiers (default: S,M,L)")
    parser.add_argument("--families", type=str, default=None,
                        help="Comma-separated case families (default: all)")
    parser.add_argument("--force", action="store_true",
                        help="Overwrite existing output directory")

    args = parser.parse_args()

    # Default output directory based on draft
    out_dir = args.out if args.out else Path(f"experiments/{args.draft}")

    # Safety check: refuse to overwrite without --force
    if out_dir.exists() and not args.force:
        print(f"Error: {out_dir} already exists. Use --force to overwrite.", file=sys.stderr)
        sys.exit(1)

    tiers = [t.strip() for t in args.tiers.split(",")]
    families = [f.strip() for f in args.families.split(",")] if args.families else None

    generate_corpus(
        out_dir=out_dir,
        draft=args.draft,
        seed=args.seed,
        n_valid=args.n_valid,
        m_invalid=args.m_invalid,
        tiers=tiers,
        families=families,
    )


if __name__ == "__main__":
    main()
