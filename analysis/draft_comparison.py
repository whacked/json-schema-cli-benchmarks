#!/usr/bin/env python3
"""
nix-shell -p python3Packages.pandas python3Packages.matplotlib python3Packages.scipy

Compare benchmark times between JSON Schema drafts, grouped by host.

Loads all runs, tags each with hostname from system.json, then computes
per-case diffs (draft-07 - draft-04) within each host. Plots grouped
bars: one group per tool, bars per host.
"""

import json
from pathlib import Path
import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
from scipy import stats


def load_run(events_path: Path) -> pd.DataFrame:
    """Load benchmark_result events from a run, tagged with hostname."""
    system_path = events_path.parent / "system.json"
    hostname = json.loads(system_path.read_text())["hostname"]

    records = []
    with open(events_path) as f:
        for line in f:
            event = json.loads(line)
            if event.get("event") == "benchmark_result":
                event["hostname"] = hostname
                records.append(event)
    return pd.DataFrame(records)


def main():
    # Load all runs for each draft
    draft04_paths = sorted(Path("results/draft-04").glob("*/events.jsonl"))
    draft07_paths = sorted(Path("results/draft-07").glob("*/events.jsonl"))

    print(f"draft-04 runs ({len(draft04_paths)}):")
    for p in draft04_paths:
        sys = json.loads((p.parent / "system.json").read_text())
        print(f"  {p.parent.name}  {sys['hostname']}")
    print(f"draft-07 runs ({len(draft07_paths)}):")
    for p in draft07_paths:
        sys = json.loads((p.parent / "system.json").read_text())
        print(f"  {p.parent.name}  {sys['hostname']}")

    df04 = pd.concat([load_run(p) for p in draft04_paths], ignore_index=True)
    df07 = pd.concat([load_run(p) for p in draft07_paths], ignore_index=True)

    # Filter: mode=file, operation=instance
    df04 = df04[(df04["mode"] == "file") & (df04["operation"] == "instance")].copy()
    df07 = df07[(df07["mode"] == "file") & (df07["operation"] == "instance")].copy()

    # Join key: match within same host, tool, case, input
    df04["key"] = df04["hostname"] + "|" + df04["case_id"] + "|" + df04["input_id"].fillna("") + "|" + df04["tool"]
    df07["key"] = df07["hostname"] + "|" + df07["case_id"] + "|" + df07["input_id"].fillna("") + "|" + df07["tool"]

    merged = pd.merge(
        df04[["key", "hostname", "tool", "case_id", "input_id", "mean_s"]],
        df07[["key", "mean_s"]],
        on="key",
        suffixes=("_04", "_07"),
    )

    merged["diff_ms"] = (merged["mean_s_07"] - merged["mean_s_04"]) * 1000

    hosts = sorted(merged["hostname"].unique())
    tools = sorted(merged["tool"].unique())
    print(f"\nHosts: {hosts}")
    print(f"Tools: {tools}")
    print(f"Total matched pairs: {len(merged)}")

    # Aggregate by (tool, hostname): median diff + bootstrapped 95% CI
    results = []
    rng = np.random.default_rng(42)
    for (tool, hostname), group in merged.groupby(["tool", "hostname"]):
        diffs = group["diff_ms"].values
        n = len(diffs)
        median_diff = np.median(diffs)
        boot_medians = [np.median(rng.choice(diffs, size=n, replace=True)) for _ in range(10000)]
        ci_lo, ci_hi = np.percentile(boot_medians, [2.5, 97.5])

        results.append({
            "tool": tool,
            "hostname": hostname,
            "n": n,
            "median_diff_ms": median_diff,
            "ci_lo_ms": ci_lo,
            "ci_hi_ms": ci_hi,
        })

    results_df = pd.DataFrame(results).sort_values(["tool", "hostname"])
    print("\nResults (positive = draft-07 slower, negative = draft-07 faster):")
    print(results_df.to_string(index=False))

    # Plot: grouped bars, one group per tool, bars per host
    fig, ax = plt.subplots(figsize=(10, max(6, len(tools) * len(hosts) * 0.5)))

    host_colors = dict(zip(hosts, plt.cm.Set2.colors))
    bar_height = 0.8 / len(hosts)
    y_positions = np.arange(len(tools))

    for i, host in enumerate(hosts):
        host_data = results_df[results_df["hostname"] == host].set_index("tool").reindex(tools)
        medians = host_data["median_diff_ms"].values
        ci_lo = host_data["ci_lo_ms"].values
        ci_hi = host_data["ci_hi_ms"].values

        # Handle NaN for tools missing on a host
        mask = ~np.isnan(medians)
        errors = [np.where(mask, medians - ci_lo, 0), np.where(mask, ci_hi - medians, 0)]

        offset = (i - (len(hosts) - 1) / 2) * bar_height
        bars = ax.barh(
            y_positions + offset, np.nan_to_num(medians), height=bar_height,
            xerr=errors, capsize=3,
            color=host_colors[host], edgecolor="black", label=host,
        )

        for bar, med, hi_val in zip(bars, medians, ci_hi):
            if np.isnan(med):
                continue
            x_pos = hi_val + 0.3 if med >= 0 else ci_lo[0] - 0.3
            ha = "left" if med >= 0 else "right"
            ax.text(x_pos, bar.get_y() + bar.get_height() / 2, f"{med:.2f}",
                    va="center", ha=ha, fontsize=8)

    ax.axvline(x=0, color="black", linestyle="-", linewidth=0.8)
    ax.set_yticks(y_positions)
    ax.set_yticklabels(tools)
    ax.set_xlabel("Time Difference (ms): draft-07 − draft-04")
    ax.set_ylabel("Tool")
    ax.set_title("Draft-07 vs Draft-04 by tool and host\n(bootstrapped 95% CI of median; positive = draft-07 slower)")
    ax.legend(title="Host")

    plt.tight_layout()
    plt.savefig("analysis/draft_comparison.png", dpi=150)
    plt.savefig("analysis/draft_comparison.svg")
    print("\nSaved: analysis/draft_comparison.png, analysis/draft_comparison.svg")
    plt.show()


if __name__ == "__main__":
    main()
