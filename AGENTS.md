# AGENTS.md

Guidance for future coding agents working in this repository.

## Issue Fixing Policy

- Unless the user explicitly asks for a temporary workaround, fix the root cause in the intended layer or contract.
- Avoid adding fallback paths, compatibility shims, feature flags, or temp solutions that mask a broken primary path.
- If fallback behavior is already product-specified, keep it narrow, documented, and tested; do not use it to avoid fixing the primary path.

## CLI Output Standards

- Keep default command output concise and action-oriented. Put paths, component/version breakdowns, command diagnostics, and failure log tails behind `-v` / `--verbose` where practical.
- Use one presentation vocabulary across user-facing scripts:
  - `==> <action>` for progress
  - `✓ <result>` for successful completion
  - `warning: <message>` for recoverable conditions or required user action
  - `error: <message>` for failures
  - `Next: <command>` for the primary follow-up action
- Use a short, plain title only when it adds context. Do not use ASCII art, boxed panels, decorative separators, emojis, or inconsistent status tokens.
- Render color only for interactive terminals and honor `NO_COLOR`. Ensure output remains clear without color.
- Show spinners only on interactive terminals; use stable line-based progress when output is redirected or piped.
- Keep help output scannable: usage first, then options grouped by purpose, followed by representative examples.
- UI/UX-only work must not change command behavior, control flow, or functional contracts.
