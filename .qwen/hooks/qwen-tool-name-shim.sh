#!/bin/bash
# qwen-tool-name-shim.sh — run a template hook with Claude Code tool names (fork-owned, WP-47).
#
# Usage (in .qwen/settings.json): qwen-tool-name-shim.sh <hook-file> [args...]
#
# WHY: Qwen Code resolves Claude names (Bash, Read, Grep, Skill) for hook MATCHERS,
# but the stdin payload carries the runtime id (run_shell_command, read_file, …).
# Template hooks compare tool_name against Claude names ("Bash", "Read", "Grep",
# "Skill", Write|Edit|MultiEdit). Wired as-is, the secret-* guards reject the unknown
# name and block every call (checked 17.09: `cat .env` via run_shell_command → rc=2
# "guard failed"), while sql-pii-guard and the Skill adapter silently skip.
# Input field names already match (file_path, command, pattern, path, skill —
# verified against QwenLM/qwen-code packages/core/src/tools, 17.09.2026).
# The shim rewrites only tool_name and passes stdin/stdout/exit code through, so the
# template hooks stay byte-identical to main and need no per-cycle transform.
#
# Missing jq/python3 (git bash on Windows ships neither jq nor python3 by default):
# the secret-* hooks fail closed and would block EVERY shell/read/MCP call, including
# the one needed to repair the install. On an offline machine that is a lockout, so
# for a missing dependency of a secret-* hook only, the shim fails open and says so in
# the agent context. Hooks that block a narrow set of calls (sql-pii-guard: .sql
# writes; Skill adapter: skills with data_needs) keep their own fail-closed handling,
# as does every other failure of any wrapped hook.

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:${PATH:-}"

HOOK_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TARGET_NAME="${1:-}"
[ -n "$TARGET_NAME" ] || { echo "qwen-tool-name-shim: hook file not given" >&2; exit 2; }
shift
case "$TARGET_NAME" in
  */*|.*) echo "qwen-tool-name-shim: hook must be a file name inside .qwen/hooks: $TARGET_NAME" >&2; exit 2 ;;
esac
TARGET="$HOOK_DIR/$TARGET_NAME"
[ -r "$TARGET" ] || { echo "qwen-tool-name-shim: hook not found: $TARGET" >&2; exit 2; }

degraded() { # <missing dependency>
  local msg="Защита $TARGET_NAME выключена: не найден $1. Установите $1 и перезапустите qwen (см. MANUAL-JOBS.md)."
  echo "⚠ $msg" >&2
  printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}\n' \
    PreToolUse "$msg"
  exit 0
}

# Probe by running, not by `command -v`: on Windows the Microsoft Store alias stub is
# found as python3 but exits non-zero without running anything (update.sh, issue #402).
PYTHON_OK=false
python3 -c 'pass' >/dev/null 2>&1 && PYTHON_OK=true

case "$TARGET_NAME" in
  secret-*)
    $PYTHON_OK || degraded python3
    jq -n 'empty' >/dev/null 2>&1 || degraded jq
    ;;
esac

INPUT=$(cat)
if $PYTHON_OK; then
  NORMALIZED=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
QWEN_TO_CLAUDE = {
    "run_shell_command": "Bash",
    "monitor": "Bash",          # runs a shell command too; Qwen maps Bash rules onto it
    "read_file": "Read",
    "grep_search": "Grep",
    "glob": "Glob",
    "edit": "Edit",
    "write_file": "Write",
    "notebook_edit": "NotebookEdit",
    "skill": "Skill",
}
raw = sys.stdin.read()
try:
    data = json.loads(raw)
except ValueError:
    sys.stdout.write(raw)       # let the wrapped hook report malformed JSON itself
    sys.exit(0)
if isinstance(data, dict) and isinstance(data.get("tool_name"), str):
    data["tool_name"] = QWEN_TO_CLAUDE.get(data["tool_name"], data["tool_name"])
sys.stdout.write(json.dumps(data, ensure_ascii=False))
') || NORMALIZED="$INPUT"
else
  NORMALIZED=$(printf '%s' "$INPUT" | jq -c '
    if type == "object" and (.tool_name | type) == "string" then
      .tool_name |= ({"run_shell_command":"Bash","monitor":"Bash","read_file":"Read",
        "grep_search":"Grep","glob":"Glob","edit":"Edit","write_file":"Write",
        "notebook_edit":"NotebookEdit","skill":"Skill"}[.] // .)
    else . end' 2>/dev/null) || NORMALIZED="$INPUT"
fi

printf '%s' "$NORMALIZED" | bash "$TARGET" "$@"
exit $?
