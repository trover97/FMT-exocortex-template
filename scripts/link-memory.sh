#!/bin/bash
# link-memory.sh — связать $WORKSPACE/memory с каталогом памяти Qwen Code.
#
# Зачем: чтобы каталог памяти был ОДИН (workspace/memory и
# ~/.qwen/projects/<id>/memory — одно и то же), а не две расходящиеся копии.
# Иначе правки MEMORY.md в workspace не попадут в авто-загрузку qwen.
#
# Стратегия (по убыванию предпочтения):
#   1) нативный симлинк (нужен Developer Mode или запуск от админа)
#   2) directory junction через mklink /J — РАБОТАЕТ БЕЗ АДМИНА на Windows
#   3) обычная копия (последнее средство; требует ручной синхронизации)
#
# Запуск:
#   bash scripts/link-memory.sh                 # workspace = $IWE_ROOT или ~/IWE
#   bash scripts/link-memory.sh --workspace DIR
#   bash scripts/link-memory.sh --force         # пересоздать, даже если memory уже есть
#
set -euo pipefail

WORKSPACE_DIR="${IWE_ROOT:-${IWE_WORKSPACE:-$HOME/IWE}}"
FORCE=false
while [ $# -gt 0 ]; do
  case "$1" in
    --workspace) WORKSPACE_DIR="$2"; shift 2 ;;
    --force)     FORCE=true; shift ;;
    --help|-h)   sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
  esac
done
WORKSPACE_DIR="${WORKSPACE_DIR/#\~/$HOME}"

# Каталог памяти Qwen: <база>/projects/<sanitizeCwd(cwd)>/memory
if command -v cygpath >/dev/null 2>&1; then
  QWEN_CWD="$(cygpath -w "$WORKSPACE_DIR" 2>/dev/null || echo "$WORKSPACE_DIR")"
else
  QWEN_CWD="$WORKSPACE_DIR"
fi
QWEN_PROJECT_ID="$(printf '%s' "$QWEN_CWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-zA-Z0-9]/-/g')"
QWEN_BASE_DIR="${QWEN_HOME:-${QWEN_RUNTIME_DIR:-$HOME/.qwen}}"
TARGET="$QWEN_BASE_DIR/projects/$QWEN_PROJECT_ID/memory"
LINK="$WORKSPACE_DIR/memory"

echo "Workspace: $WORKSPACE_DIR"
echo "Link:      $LINK"
echo "Target:    $TARGET"

mkdir -p "$WORKSPACE_DIR" "$TARGET"

# Если LINK уже корректная ссылка/junction — выходим.
if [ -L "$LINK" ]; then echo "✓ Уже симлинк — ничего не делаю."; exit 0; fi

# Если LINK существует и это копия — сначала перенесём её содержимое в TARGET,
# чтобы не потерять правки, затем заменим ссылкой.
if [ -e "$LINK" ]; then
  if ! $FORCE; then
    echo "⚠ $LINK уже существует (вероятно копия). Запусти с --force, чтобы заменить ссылкой."
    echo "  Содержимое копии сначала будет слито в $TARGET (новее не перезатирается)."
    exit 2
  fi
  echo "  Сливаю содержимое копии в $TARGET (cp -n, без перезатирания)..."
  cp -rn "$LINK"/. "$TARGET"/ 2>/dev/null || true
  rm -rf "$LINK"
fi

# 1) нативный симлинк
if MSYS=winsymlinks:nativestrict ln -s "$TARGET" "$LINK" 2>/dev/null && [ -L "$LINK" ]; then
  echo "✓ Создан симлинк (native): $LINK → $TARGET"; exit 0
fi
rm -rf "$LINK" 2>/dev/null || true

# 2) directory junction (без админа)
if command -v cygpath >/dev/null 2>&1; then
  WIN_LINK="$(cygpath -w "$LINK")"
  WIN_TARGET="$(cygpath -w "$TARGET")"
  if MSYS_NO_PATHCONV=1 cmd //c mklink /J "$WIN_LINK" "$WIN_TARGET" >/dev/null 2>&1 && [ -d "$LINK" ]; then
    echo "✓ Создан junction (Windows, без админа): $LINK → $TARGET"; exit 0
  fi
fi
rm -rf "$LINK" 2>/dev/null || true

# 3) копия (последнее средство)
cp -r "$TARGET" "$LINK"
echo "⚠ Ни симлинк, ни junction не вышли → СКОПИРОВАНО."
echo "  Включи Developer Mode (Параметры → Конфиденциальность → Для разработчиков)"
echo "  и перезапусти: bash scripts/link-memory.sh --force"
echo "  Пока что синхронизируй вручную: cp \"$TARGET\"/*.md \"$LINK\"/"
exit 0
