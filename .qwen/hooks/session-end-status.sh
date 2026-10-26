#!/usr/bin/env bash
# SessionEnd — fail-safe agent-status write (issue #266, РП-395 Ф3 promise).
# agent-status-report.sh never fails the caller (always exit 0 itself); this
# hook mirrors that and never blocks session end.
set -uo pipefail

# === OFFLINE GUARD (qwen-windows-offline branch, A16) ===
# Эта ветка работает без интернета. Хук писал бы статус агента в базу Neon через psql
# (нужны файл секретов и psql), а прокси такой канал не останавливает. Удали блок,
# чтобы включить запись статуса. Контракт хука: в stdout печатается {}.
echo '{}'
exit 0
# === /OFFLINE GUARD ===

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$(cd "${HOOK_DIR}/.." && pwd)"
# shellcheck source=../lib/iwe-env-bootstrap.sh
source "$CLAUDE_DIR/lib/iwe-env-bootstrap.sh" 2>/dev/null || { echo '{}'; exit 0; }

STATUS_SCRIPT="$IWE_SCRIPTS/agent-status-report.sh"
[ -x "$STATUS_SCRIPT" ] && bash "$STATUS_SCRIPT" claude-code idle 2>/dev/null

echo '{}'
exit 0
