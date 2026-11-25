#!/usr/bin/env python3
"""Prepare the GPU server for Inkling with native llama.cpp on this host."""

import argparse

from mn_sdk import resolve_model_entry
from mn_sdk.models.dmr.runner import prepare, settings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend", choices=["metal", "cuda", "hip", "vulkan", "cpu"])
    args = parser.parse_args()
    try:
        entry = resolve_model_entry("inkling-2-mini")
        selected = settings(entry).accelerator
        requested = "vulkan" if args.backend == "hip" else args.backend
        if requested and requested != selected:
            raise ValueError(f"The native llama.cpp backend on this host is {selected}")
        result = prepare(entry)
    except (ValueError, RuntimeError, OSError) as exc:
        parser.exit(1, f"error: {exc}\n")
    print(f"Prepared native llama-server {result['binary']}")


if __name__ == "__main__":
    main()
