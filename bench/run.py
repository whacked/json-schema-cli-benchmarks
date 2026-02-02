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
import os
import platform
import shlex
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Iterator, Literal

import orjson
import typer
import yaml
from loguru import logger
from pydantic import ValidationError
from tqdm import tqdm

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
from models.system import SystemInformation

app = typer.Typer()

# Exit code to outcome mapping
EXIT_CODE_OUTCOME = {
    0: Outcome.VALID,
    1: Outcome.INVALID,
    2: Outcome.UNSUPPORTED,
}

# -----------------------------------------------------------------------------
# Output capture configuration
# -----------------------------------------------------------------------------
# Set to True to capture stdout/stderr from correctness runs.
# When enabled, writes to results/<draft>/runs/<job_id>/stdout.txt and stderr.txt
# alongside hyperfine.json (if speed benchmarks are enabled).
# Useful for debugging mismatches or analyzing error messages across tools.
CAPTURE_OUTPUT = False


# -----------------------------------------------------------------------------
# System information gathering
# -----------------------------------------------------------------------------


def get_cpu_info() -> tuple[str | None, int | None]:
    """Get CPU model and core count (platform-specific)."""
    cpu_model = None
    cpu_cores = os.cpu_count()

    try:
        if sys.platform == "darwin":
            # macOS: use sysctl
            result = subprocess.run(
                ["sysctl", "-n", "machdep.cpu.brand_string"],
                capture_output=True,
                text=True,
                timeout=5,
            )
            if result.returncode == 0:
                cpu_model = result.stdout.strip()
        elif sys.platform == "linux":
            # Linux: parse /proc/cpuinfo
            with open("/proc/cpuinfo") as f:
                for line in f:
                    if line.startswith("model name"):
                        cpu_model = line.split(":")[1].strip()
                        break
    except Exception:
        pass

    return cpu_model, cpu_cores


def get_ram_bytes() -> int | None:
    """Get total RAM in bytes (platform-specific)."""
    try:
        if sys.platform == "darwin":
            result = subprocess.run(
                ["sysctl", "-n", "hw.memsize"],
                capture_output=True,
                text=True,
                timeout=5,
            )
            if result.returncode == 0:
                return int(result.stdout.strip())
        elif sys.platform == "linux":
            with open("/proc/meminfo") as f:
                for line in f:
                    if line.startswith("MemTotal:"):
                        # Value is in kB
                        kb = int(line.split()[1])
                        return kb * 1024
    except Exception:
        pass
    return None


def get_git_info(repo_root: Path) -> tuple[str | None, bool | None]:
    """Get git SHA and dirty status."""
    git_sha = None
    git_dirty = None

    try:
        result = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            cwd=repo_root,
            timeout=5,
        )
        if result.returncode == 0:
            git_sha = result.stdout.strip()[:12]  # Short SHA

        result = subprocess.run(
            ["git", "status", "--porcelain"],
            capture_output=True,
            text=True,
            cwd=repo_root,
            timeout=5,
        )
        if result.returncode == 0:
            git_dirty = len(result.stdout.strip()) > 0
    except Exception:
        pass

    return git_sha, git_dirty


def gather_system_info(repo_root: Path, command: str) -> SystemInformation:
    """Gather system information for benchmark reproducibility."""
    cpu_model, cpu_cores = get_cpu_info()
    ram_bytes = get_ram_bytes()
    git_sha, git_dirty = get_git_info(repo_root)

    return SystemInformation(
        hostname=platform.node(),
        platform=sys.platform,
        platform_version=platform.platform(),
        architecture=platform.machine(),
        cpu_model=cpu_model,
        cpu_cores=cpu_cores,
        ram_bytes=ram_bytes,
        python_version=platform.python_version(),
        run_id=datetime.now(timezone.utc),
        git_sha=git_sha,
        git_dirty=git_dirty,
        command=command,
    )


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

    @property
    def schema_bytes(self) -> int:
        """Size of schema file in bytes."""
        return self.schema_path.stat().st_size

    @property
    def instance_bytes(self) -> int | None:
        """Size of instance file in bytes, or None for schema-only operations."""
        if self.instance_path is None:
            return None
        return self.instance_path.stat().st_size


def enumerate_jobs_for_case(
    draft: str,
    case_id: str,
    case_spec: CaseSpec,
    case_dir: Path,
    tool: str,
    tool_version: str,
) -> Iterator[Job]:
    """Generate all jobs for a single case."""
    schema_path = case_dir / "schema.json"

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


def count_instances_for_case(case_dir: Path, case_spec: CaseSpec) -> int:
    """Count instances for a case (for progress display)."""
    if not case_spec.schema_valid or case_spec.instance_valid is None:
        return 0
    return len(expand_instances(case_dir, case_spec))


def enumerate_jobs(
    manifest: ExperimentManifest,
    experiment_dir: Path,
    tool: str,
    tool_version: str,
) -> Iterator[Job]:
    """Generate all jobs for a tool × manifest (flat iterator for compatibility)."""
    draft = manifest.draft.value
    cases_dir = experiment_dir / "cases"

    for case_id, case_spec in manifest.cases.items():
        case_dir = cases_dir / case_id
        schema_path = case_dir / "schema.json"

        if not schema_path.exists():
            logger.warning(f"Skipping {case_id}: no schema.json")
            continue

        yield from enumerate_jobs_for_case(
            draft, case_id, case_spec, case_dir, tool, tool_version
        )


def run_correctness(
    job: Job,
    adapter: Path,
    runs_dir: Path | None = None,
) -> CorrectnessResult:
    """Execute correctness check for a job.

    Args:
        job: The job to run
        adapter: Path to the adapter script
        runs_dir: If CAPTURE_OUTPUT is True, base directory for output files.
                  Writes to runs_dir/<job_id>/stdout.txt and stderr.txt
    """
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

    # Capture stdout/stderr if enabled (writes to runs/<job_id>/ alongside hyperfine.json)
    stdout_path = None
    stderr_path = None
    if CAPTURE_OUTPUT and runs_dir is not None:
        job_dir = runs_dir / job.job_id
        job_dir.mkdir(parents=True, exist_ok=True)

        if stdout:
            stdout_file = job_dir / "stdout.txt"
            stdout_file.write_text(stdout)
            stdout_path = relpath(stdout_file)

        if stderr:
            stderr_file = job_dir / "stderr.txt"
            stderr_file.write_text(stderr)
            stderr_path = relpath(stderr_file)

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
        schema_bytes=job.schema_bytes,
        instance_bytes=job.instance_bytes,
        exit_code=exit_code,
        outcome=outcome,
        expected=job.expected,
        match=match,
        stdout_path=stdout_path,
        stderr_path=stderr_path,
    )


def relpath(path: Path) -> str:
    """Convert path to relative path from cwd."""
    return os.path.relpath(path, os.getcwd())


def run_benchmark(
    job: Job,
    adapter: Path,
    runs_dir: Path,
    warmup: int = 3,
    runs: int = 10,
) -> BenchmarkResult | None:
    """Execute hyperfine benchmark for a job."""
    ts = datetime.now(timezone.utc)

    # Build the command to benchmark (use relative paths for reproducibility)
    adapter_rel = relpath(adapter)
    schema_rel = relpath(job.schema_path)
    instance_rel = relpath(job.instance_path) if job.instance_path else None

    if job.operation == "schema":
        cmd = f"{adapter_rel} validate-schema {schema_rel}"
    elif job.mode == "file":
        cmd = f"{adapter_rel} validate-instance {schema_rel} {instance_rel}"
    else:
        cmd = f"cat {instance_rel} | {adapter_rel} validate-instance-stdin {schema_rel}"

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
            schema_bytes=job.schema_bytes,
            instance_bytes=job.instance_bytes,
            mean_s=bench["mean"],
            stddev_s=bench["stddev"],
            min_s=bench["min"],
            max_s=bench["max"],
            runs=len(bench["times"]),
            hyperfine_json_path=relpath(hyperfine_json),
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


def run_single_job(
    job: Job,
    adapter: Path,
    jobs_dir: Path,
    skip_speed: bool,
    warmup: int,
    runs: int,
) -> tuple[CorrectnessResult, BenchmarkResult | None]:
    """Execute a single job (correctness + optional benchmark).

    This function is the unit of work for parallel execution. It stays
    sequential internally, so ipdb works when parallelism=1.

    Returns:
        Tuple of (correctness_result, benchmark_result or None)
    """
    # Correctness check
    correctness = run_correctness(job, adapter, jobs_dir if CAPTURE_OUTPUT else None)

    benchmark = None
    if correctness.match and not skip_speed and correctness.status == Status.ok:
        benchmark = run_benchmark(job, adapter, jobs_dir, warmup, runs)

    return (correctness, benchmark)


@contextmanager
def job_processor(
    jobs: list,
    worker_fn: Callable,
    parallelism: int,
):
    """Context manager that yields an iterator over job results.

    Encapsulates the parallel/serial execution difference so the consumer
    code (write loop) is identical regardless of mode.

    - parallelism=1: Runs in main thread (debuggable with ipdb)
    - parallelism>1: Uses thread pool, streams results via as_completed()

    Results arrive in completion order when parallel, but each result
    contains full job metadata so order doesn't matter for event logging.
    """
    if parallelism == 1:
        # Serial: generator runs in main thread - ipdb works
        yield (worker_fn(job) for job in jobs)
    else:
        # Parallel: thread pool with as_completed for streaming results
        with ThreadPoolExecutor(max_workers=parallelism) as executor:
            futures = [executor.submit(worker_fn, job) for job in jobs]
            yield (f.result() for f in as_completed(futures))


@app.command()
def main(
    draft: str = typer.Argument(..., help="Draft to benchmark (e.g., draft-07)"),
    skip_speed: bool = typer.Option(False, "--skip-speed", help="Skip speed benchmarks"),
    tool_filter: str | None = typer.Option(None, "--tool", help="Only run this tool"),
    warmup: int = typer.Option(3, "--warmup", help="Hyperfine warmup runs"),
    runs: int = typer.Option(10, "--runs", help="Hyperfine benchmark runs"),
    parallelism: int = typer.Option(
        max((os.cpu_count() or 1) - 2, 1),
        "--parallelism", "-j",
        help="Number of parallel workers (default: cpu_count - 2)",
    ),
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

    # Gather system info (run_id is the timestamp)
    command = shlex.join(sys.argv)
    system_info = gather_system_info(repo_root, command)
    run_id = system_info.run_id.strftime("%Y-%m-%dT%H-%M-%S")

    # Prepare output directories: results/<draft>/<run_id>/{system.json, events.jsonl, jobs/}
    run_dir = results_dir / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    jobs_dir = run_dir / "jobs"
    jobs_dir.mkdir(exist_ok=True)
    events_file = run_dir / "events.jsonl"

    # Initialize events file
    events_file.write_text("")

    # Write system information
    system_file = run_dir / "system.json"
    with open(system_file, "w") as f:
        # Use model_dump with mode='json' for proper datetime serialization
        data = system_info.model_dump(mode="json")
        json.dump(data, f, indent=2)
        f.write("\n")
    logger.info(f"System info: {system_info.platform} {system_info.architecture}, {system_info.cpu_cores} cores")
    logger.info(f"Run ID: {run_id}, parallelism: {parallelism}")

    # Stats
    total_jobs = 0
    matched = 0
    mismatched = 0
    benchmarked = 0

    # Pre-compute case list and counts for progress display
    cases_dir = experiment_dir / "cases"
    case_list = []
    for case_id, case_spec in manifest.cases.items():
        case_dir = cases_dir / case_id
        if not (case_dir / "schema.json").exists():
            logger.warning(f"Skipping {case_id}: no schema.json")
            continue
        instance_count = count_instances_for_case(case_dir, case_spec)
        case_list.append((case_id, case_spec, case_dir, instance_count))

    total_cases = len(case_list)
    total_instances = sum(ic for _, _, _, ic in case_list)
    logger.info(f"Total: {total_cases} cases, {total_instances} instances")

    # Collect all jobs upfront (for all tools × cases)
    all_jobs: list[tuple[Job, Path]] = []  # (job, adapter)
    for adapter in adapters:
        tool_name = adapter.stem
        tool_version = get_tool_version(adapter)
        logger.info(f"Tool: {tool_name} ({tool_version})")

        draft_val = manifest.draft.value
        for case_id, case_spec, case_dir, _ in case_list:
            for job in enumerate_jobs_for_case(
                draft_val, case_id, case_spec, case_dir, tool_name, tool_version
            ):
                all_jobs.append((job, adapter))

    total_jobs = len(all_jobs)
    logger.info(f"Collected {total_jobs} jobs to run")

    # Create worker function with fixed arguments
    def worker(job_adapter: tuple[Job, Path]) -> tuple[CorrectnessResult, BenchmarkResult | None]:
        job, adapter = job_adapter
        return run_single_job(job, adapter, jobs_dir, skip_speed, warmup, runs)

    # Run jobs and write results as they complete
    # Uses job_processor context manager to handle parallel/serial uniformly
    logger.info(f"\n{'='*60}")
    logger.info(f"Running jobs...")
    logger.info(f"{'='*60}")

    with job_processor(all_jobs, worker, parallelism) as results:
        for correctness, benchmark in tqdm(results, total=total_jobs, desc="Jobs"):
            # Write event immediately as each result arrives
            write_event(events_file, correctness)

            if correctness.match:
                matched += 1
                if benchmark:
                    write_event(events_file, benchmark)
                    benchmarked += 1
            else:
                mismatched += 1

    # Summary
    logger.info("")
    logger.info(f"{'='*60}")
    logger.info(f"COMPLETE: {draft}")
    logger.info(f"{'='*60}")
    logger.info(f"Results written to: {run_dir}")
    logger.info(f"Cases: {total_cases}, Instances: {total_instances}")
    logger.info(f"Jobs: {total_jobs} total, {matched} matched, {mismatched} mismatched")
    if not skip_speed:
        logger.info(f"Benchmarked: {benchmarked} jobs")

    if mismatched > 0:
        raise typer.Exit(1)


if __name__ == "__main__":
    app()
