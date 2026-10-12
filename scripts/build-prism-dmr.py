#!/usr/bin/env python3
"""Prepare Bonsai2's catalog-declared DMR backend through the installed SDK.

Normal model installation and first use already run this preparation. This
entrypoint is only for warming the backend cache without downloading weights.
"""

import argparse

from mn_sdk import prepare_dmr_model, resolve_model_entry
from mn_sdk.dmr_managed import managed_descriptor


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend", choices=["metal", "cuda", "hip", "vulkan", "cpu"], default=None)
    args = parser.parse_args()
    try:
        entry = prepare_dmr_model(resolve_model_entry("small"), accelerator=args.backend)
        state = managed_descriptor(entry, required=True)
    except (ValueError, RuntimeError, OSError) as exc:
        parser.exit(1, f"error: {exc}\n")
    print(f"Prepared catalog DMR backend: {state['root']}")
    print("Next: mn model add small --local")


if __name__ == "__main__":
    main()
