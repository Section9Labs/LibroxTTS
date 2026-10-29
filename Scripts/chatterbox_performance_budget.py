#!/usr/bin/env python3
"""Evaluate finished Mac diagnostic receipts against an audio/playback target.

Reads existing numeric receipts only. Does not load models, render audio, access
devices or copy text/voice data. Stage floors are optimistic bounds, not measured
pipeline speedups or energy predictions.
"""
import argparse
import json
import math
import pathlib


def positive(value, name):
    value = float(value)
    if not math.isfinite(value) or value <= 0:
        raise ValueError(f"Invalid {name}")
    return value


def evaluate(report, speed, playback_rate):
    if report.get("completed") is not True or not report.get("clips"):
        raise ValueError("A successfully completed diagnostic receipt is required")
    clips = report["clips"]
    audio = sum(positive(c["audio_seconds"], "audio duration") for c in clips)
    wall = sum(positive(c["wall_seconds"], "render wall") for c in clips)
    stages = {}
    for key in ["assembly_seconds", "prefill_seconds", "decode_seconds", "synth_seconds"]:
        values = [float(c[key]) for c in clips]
        if any(not math.isfinite(v) or v < 0 for v in values):
            raise ValueError(f"Invalid {key}")
        stages[key] = sum(values)
    playback_duration = audio / playback_rate
    target_wall = playback_duration / speed
    token_seconds = stages["assembly_seconds"] + stages["prefill_seconds"] + stages["decode_seconds"]
    return {
        "scope": "Warm render receipts; excludes cold load. Not phone, sustained or energy acceptance.",
        "profile": report["profile"],
        "clips": len(clips),
        "playback_rate": playback_rate,
        "required_generation_multiple_of_playback": speed,
        "audio_seconds": audio,
        "render_wall_seconds": wall,
        "maximum_allowed_wall_seconds": target_wall,
        "current_generation_multiple_of_playback": playback_duration / wall,
        "required_total_throughput_improvement": wall / target_wall,
        "meets_target_in_this_sample": wall <= target_wall,
        "stage_seconds": stages,
        "optimistic_minimum_wall_with_free_decoder_seconds": stages["synth_seconds"],
        "optimistic_minimum_wall_with_free_acoustics_seconds": token_seconds,
        "optimistic_stage_overlap_floor_seconds": max(token_seconds, stages["synth_seconds"]),
        "minimum_acoustic_speedup_even_with_free_decoder": max(1, stages["synth_seconds"] / target_wall),
        "minimum_decoder_speedup_even_with_free_acoustics": max(1, token_seconds / target_wall),
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=pathlib.Path)
    parser.add_argument("--speed", type=float, default=5)
    parser.add_argument("--playback-rate", type=float, default=1)
    args = parser.parse_args()
    result = evaluate(json.loads(args.report.read_text()),
                      positive(args.speed, "speed"), positive(args.playback_rate, "playback rate"))
    print(json.dumps(result, indent=2))
