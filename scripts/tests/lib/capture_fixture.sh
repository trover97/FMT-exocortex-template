#!/usr/bin/env bash
# capture_fixture.sh — shared fixture builder for capture-bus.sh contract tests.
#
# capture-bus.sh resolves its own directory via `dirname "${BASH_SOURCE[0]}"`
# (HOOK_DIR/CLAUDE_DIR), so it must run from a real .qwen/hooks/ layout, not
# a lone copy in a bare tmpdir — a bare copy either can't find lib/config at
# all, or (when run from its real location without a stdin payload) exits
# immediately via the empty-stdin guard before reaching any detector. Building
# a minimal-but-complete .qwen/ tree sidesteps both traps.

setup_capture_fixture() {
  local template_root=$1
  local fixture_root=$2

  mkdir -p \
    "$fixture_root/.qwen/hooks" \
    "$fixture_root/.qwen/lib" \
    "$fixture_root/.qwen/config" \
    "$fixture_root/.qwen/logs"

  cp "$template_root/.qwen/hooks/capture-bus.sh" \
    "$fixture_root/.qwen/hooks/"
  cp "$template_root/.qwen/lib/iwe-env-bootstrap.sh" \
    "$template_root/.qwen/lib/log_formatter.sh" \
    "$template_root/.qwen/lib/capture_writer.sh" \
    "$fixture_root/.qwen/lib/"

  export WORKSPACE_DIR="$fixture_root"
  export IWE_ROOT="$fixture_root"
  export IWE_TEMPLATE="$template_root"
  export CAPTURE_LOG_FILE="$fixture_root/.qwen/logs/capture_log.jsonl"
}
