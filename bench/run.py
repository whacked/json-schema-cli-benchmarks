#!/usr/bin/env python3
"""
Unified benchmark runner for JSON Schema validator CLIs.

Loads manifest, runs correctness checks, optionally runs speed benchmarks,
writes events to events.jsonl.

Usage:
    python bench/run.py draft-07
    python bench/run.py draft-07 --skip-speed
    python bench/run.py draft-07 --tool check-jsonschema
"""

from __future__ import annotations

import glob
import hashlib
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator, Literal

import orjson
import typer
import yaml
from loguru import logger
from pydantic import ValidationError

# Add src to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

from models import ExperimentManifest, CaseSpec, Draft
from models.events import (
    CorrectnessResult,
    BenchmarkResult,
    Outcome,
    Mode,
    Operation,
    Status,
)

app = typer.Typer()

# Exit code to outcome mapping
EXIT_CODE_OUTCOME = {
    0: Outcome.VALID,
    1: Outcome.INVALID,
    2: Outcome.UNSUPPORTED,
}


def compute_job_id(
    draft: str,
    tool: str,
    case_id: str,
    operation: str,
    mode: str,
    input_id: str | None = None,
) -> str:
    """Compute stable job_id from canonical JSON of job dimensions."""
    obj = {
        "case_id": case_id,
        "draft": draft,
        "input_id": input_id,
        "mode": mode,
        "operation": operation,
        "tool": tool,
    }
    # orjson sorts keys and produces deterministic output
    canonical = orjson.dumps(obj, option=orjson.OPT_SORT_KEYS)
    return hashlib.sha256(canonical).hexdigest()[:16]


def load_manifest(experiment_dir: Path) -> ExperimentManifest:
    """Load and validate manifest (YAML preferred, JSON fallback)."""
    yaml_path = experiment_dir / "manifest.yaml"
    json_path = experiment_dir / "manifest.json"

    if yaml_path.exists():
        with open(yaml_path) as f:
            data = yaml.safe_load(f)
    elif json_path.exists():
        with open(json_path) as f:
            data = json.load(f)
    else:
        raise FileNotFoundError(
            f"Manifest not found: {yaml_path} or {json_path}"
        )

    # Remove deprecated meta_schema field if present
    data.pop("meta_schema", None)

    return ExperimentManifest.model_validate(data)


def discover_adapters(adapters_dir: Path) -> list[Path]:
    """Find all adapter scripts."""
    adapters = sorted(adapters_dir.glob("*.sh"))
    if not adapters:
        raise FileNotFoundError(f"No adapters found in {adapters_dir}")
    return adapters


def get_tool_version(adapter: Path) -> str:
    """Get tool version from adapter."""
    try:
        result = subprocess.run(
            [str(adapter), "version"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        return result.stdout.strip() or "unknown"
    except Exception:
        return "unknown"


def run_adapter(
    adapter: Path,
    command: str,
    args: list[str],
    stdin_data: bytes | None = None,
) -> tuple[int, str, str]:
    """Run adapter command, return (exit_code, stdout, stderr)."""
    try:
        result = subprocess.run(
            [str(adapter), command] + args,
            input=stdin_data,
            capture_output=True,
            timeout=60,
        )
        return result.returncode, result.stdout.decode(), result.stderr.decode()
    except subprocess.TimeoutExpired:
        return 3, "", "timeout"
    except Exception as e:
        return 3, "", str(e)


def expand_instances(case_dir: Path, case_spec: CaseSpec) -> list[Path]:
    """Expand instance glob pattern to concrete files."""
    if case_spec.instances:
        pattern = str(case_dir / case_spec.instances)
        return sorted(Path(p) for p in glob.glob(pattern, recursive=True))
    else:
        # Default: single instance.json
        instance = case_dir / "instance.json"
        return [instance] if instance.exists() else []


def determine_match(outcome: Outcome, expected: bool) -> bool:
    """Determine if outcome matches expected validity."""
    if outcome == Outcome.VALID:
        return expected is True
    elif outcome == Outcome.INVALID:
        return expected is False
    else:
        return False


def determine_status(exit_code: int) -> Status:
    """Map exit code to status."""
    if exit_code == 0 or exit_code == 1:
        return Status.ok
    elif exit_code == 2:
        return Status.unsupported
    else:
        return Status.error


class Job:
    """Represents a single benchmark job."""

    def __init__(
        self,
        draft: str,
        tool: str,
        tool_version: str,
        case_id: str,
        operation: Literal["schema", "instance"],
        mode: Literal["file", "stdin"],
        schema_path: Path,
        instance_path: Path | None = None,
        expected: bool = True,
        input_id: str | None = None,
    ):
        self.draft = draft
        self.tool = tool
        self.tool_version = tool_version
        self.case_id = case_id
        self.operation = operation
        self.mode = mode
        self.schema_path = schema_path
        self.instance_path = instance_path
        self.expected = expected
        self.input_id = input_id
        self.job_id = compute_job_id(
            draft, tool, case_id, operation, mode, input_id
        )


def enumerate_jobs(
    manifest: ExperimentManifest,
    experiment_dir: Path,
    tool: str,
    tool_version: str,
) -> Iterator[Job]:
    """Generate all jobs for a tool × manifest."""
    draft = manifest.draft.value
    cases_dir = experiment_dir / "cases"

    for case_id, case_spec in manifest.cases.items():
        case_dir = cases_dir / case_id
        schema_path = case_dir / "schema.json"

        if not schema_path.exists():
            logger.warning(f"Skipping {case_id}: no schema.json")
            continue

        # Schema validation always runs (file mode only)
        yield Job(
            draft=draft,
            tool=tool,
            tool_version=tool_version,
            case_id=case_id,
            operation="schema",
            mode="file",
            schema_path=schema_path,
            expected=case_spec.schema_valid,
        )

        # Instance validation only runs if schema is valid
        if case_spec.schema_valid and case_spec.instance_valid is not None:
            instances = expand_instances(case_dir, case_spec)
            for instance_path in instances:
                # Compute input_id as relative path from case instances dir
                if case_spec.instances:
                    input_id = str(instance_path.relative_to(case_dir / "instances"))
                else:
                    input_id = instance_path.name

                # File mode
                yield Job(
                    draft=draft,
                    tool=tool,
                    tool_version=tool_version,
                    case_id=case_id,
                    operation="instance",
                    mode="file",
                    schema_path=schema_path,
                    instance_path=instance_path,
                    expected=case_spec.instance_valid,
                    input_id=input_id,
                )

                # Stdin mode
                yield Job(
                    draft=draft,
                    tool=tool,
                    tool_version=tool_version,
                    case_id=case_id,
                    operation="instance",
                    mode="stdin",
                    schema_path=schema_path,
                    instance_path=instance_path,
                    expected=case_spec.instance_valid,
                    input_id=input_id,
                )


def run_correctness(job: Job, adapter: Path) -> CorrectnessResult:
    """Execute correctness check for a job."""
    ts = datetime.now(timezone.utc)

    if job.operation == "schema":
        exit_code, stdout, stderr = run_adapter(
            adapter, "validate-schema", [str(job.schema_path)]
        )
    elif job.mode == "file":
        exit_code, stdout, stderr = run_adapter(
            adapter,
            "validate-instance",
            [str(job.schema_path), str(job.instance_path)],
        )
    else:  # stdin
        with open(job.instance_path, "rb") as f:
            stdin_data = f.read()
        exit_code, stdout, stderr = run_adapter(
            adapter,
            "validate-instance-stdin",
            [str(job.schema_path)],
            stdin_data=stdin_data,
        )

    outcome = EXIT_CODE_OUTCOME.get(exit_code, Outcome.ERROR)
    match = determine_match(outcome, job.expected)
    status = determine_status(exit_code)

    return CorrectnessResult(
        event="correctness_result",
        ts=ts,
        draft=job.draft,
        tool=job.tool,
        tool_version=job.tool_version,
        case_id=job.case_id,
        operation=Operation(job.operation),
        mode=Mode(job.mode),
        job_id=job.job_id,
        input_id=job.input_id,
        status=status,
        exit_code=exit_code,
        outcome=outcome,
        expected=job.expected,
        match=match,
        stdout_path=None,
        stderr_path=None,
    )


def run_benchmark(
    job: Job,
    adapter: Path,
    runs_dir: Path,
    warmup: int = 3,
    runs: int = 10,
) -> BenchmarkResult | None:
    """Execute hyperfine benchmark for a job."""
    ts = datetime.now(timezone.utc)

    # Build the command to benchmark
    if job.operation == "schema":
        cmd = f"{adapter} validate-schema {job.schema_path}"
    elif job.mode == "file":
        cmd = f"{adapter} validate-instance {job.schema_path} {job.instance_path}"
    else:
        cmd = f"cat {job.instance_path} | {adapter} validate-instance-stdin {job.schema_path}"

    # Output path
    job_dir = runs_dir / job.job_id
    job_dir.mkdir(parents=True, exist_ok=True)
    hyperfine_json = job_dir / "hyperfine.json"

    try:
        result = subprocess.run(
            [
                "hyperfine",
                "--warmup", str(warmup),
                "--runs", str(runs),
                "--export-json", str(hyperfine_json),
                "--shell", "bash",
                "--ignore-failure",  # Allow non-zero exits (INVALID cases)
                cmd,
            ],
            capture_output=True,
            timeout=300,
        )
        if result.returncode != 0:
            logger.warning(f"hyperfine failed for {job.job_id}: {result.stderr.decode()}")
            return None

        # Parse hyperfine output
        with open(hyperfine_json) as f:
            hf_data = json.load(f)

        bench = hf_data["results"][0]
        return BenchmarkResult(
            event="benchmark_result",
            ts=ts,
            draft=job.draft,
            tool=job.tool,
            tool_version=job.tool_version,
            case_id=job.case_id,
            operation=Operation(job.operation),
            mode=Mode(job.mode),
            job_id=job.job_id,
            input_id=job.input_id,
            status=Status.ok,
            mean_s=bench["mean"],
            stddev_s=bench["stddev"],
            min_s=bench["min"],
            max_s=bench["max"],
            runs=len(bench["times"]),
            hyperfine_json_path=str(hyperfine_json),
        )

    except subprocess.TimeoutExpired:
        logger.error(f"hyperfine timeout for {job.job_id}")
        return None
    except Exception as e:
        logger.error(f"hyperfine error for {job.job_id}: {e}")
        return None


def write_event(events_file: Path, event: CorrectnessResult | BenchmarkResult) -> None:
    """Append event to events.jsonl."""
    with open(events_file, "a") as f:
        # Use model_dump with mode='json' for serialization
        data = event.model_dump(mode="json")
        f.write(orjson.dumps(data).decode() + "\n")


@app.command()
def main(
    draft: str = typer.Argument(..., help="Draft to benchmark (e.g., draft-07)"),
    skip_speed: bool = typer.Option(False, "--skip-speed", help="Skip speed benchmarks"),
    tool_filter: str | None = typer.Option(None, "--tool", help="Only run this tool"),
    warmup: int = typer.Option(3, "--warmup", help="Hyperfine warmup runs"),
    runs: int = typer.Option(10, "--runs", help="Hyperfine benchmark runs"),
) -> None:
    """Run benchmarks for a draft."""
    repo_root = Path(__file__).parent.parent
    experiment_dir = repo_root / "experiments" / draft
    results_dir = repo_root / "results" / draft
    adapters_dir = repo_root / "tools" / "adapters"

    # Load manifest
    try:
        manifest = load_manifest(experiment_dir)
        logger.info(f"Loaded manifest: {draft} with {len(manifest.cases)} cases")
    except FileNotFoundError as e:
        logger.error(str(e))
        raise typer.Exit(1)
    except ValidationError as e:
        logger.error(f"Invalid manifest: {e}")
        raise typer.Exit(1)

    # Discover adapters
    try:
        adapters = discover_adapters(adapters_dir)
        if tool_filter:
            adapters = [a for a in adapters if a.stem == tool_filter]
            if not adapters:
                logger.error(f"Tool not found: {tool_filter}")
                raise typer.Exit(1)
        logger.info(f"Found {len(adapters)} adapter(s)")
    except FileNotFoundError as e:
        logger.error(str(e))
        raise typer.Exit(1)

    # Prepare output directories
    results_dir.mkdir(parents=True, exist_ok=True)
    runs_dir = results_dir / "runs"
    runs_dir.mkdir(exist_ok=True)
    events_file = results_dir / "events.jsonl"

    # Truncate events file
    events_file.write_text("")

    # Stats
    total_jobs = 0
    matched = 0
    mismatched = 0
    benchmarked = 0

    # Run benchmarks
    for adapter in adapters:
        tool_name = adapter.stem
        tool_version = get_tool_version(adapter)
        logger.info(f"Tool: {tool_name} ({tool_version})")

        for job in enumerate_jobs(manifest, experiment_dir, tool_name, tool_version):
            total_jobs += 1

            # Correctness check
            result = run_correctness(job, adapter)
            write_event(events_file, result)

            status_icon = "✓" if result.match else "✗"
            logger.info(
                f"  {status_icon} {job.case_id}/{job.operation}({job.mode}): "
                f"{result.outcome.value} (expected={result.expected}, match={result.match})"
            )

            if result.match:
                matched += 1

                # Speed benchmark (only if correctness passed)
                if not skip_speed and result.status == Status.ok:
                    bench_result = run_benchmark(job, adapter, runs_dir, warmup, runs)
                    if bench_result:
                        write_event(events_file, bench_result)
                        benchmarked += 1
                        logger.info(
                            f"    ⏱ {bench_result.mean_s:.4f}s ± {bench_result.stddev_s:.4f}s"
                        )
            else:
                mismatched += 1

    # Summary
    logger.info("")
    logger.info(f"Results written to: {events_file}")
    logger.info(f"Summary: {total_jobs} jobs, {matched} matched, {mismatched} mismatched")
    if not skip_speed:
        logger.info(f"Benchmarked: {benchmarked} jobs")

    if mismatched > 0:
        raise typer.Exit(1)


if __name__ == "__main__":
    app()
