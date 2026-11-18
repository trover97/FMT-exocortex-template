#!/bin/bash
# link-memory.sh — связать $WORKSPACE/memory с каталогом памяти Qwen Code.
#
# Зачем: чтобы каталог памяти был ОДИН (workspace/memory и
# ~/.qwen/projects/<id>/memory — одно и то же), а не две расходящиеся копии.
# Иначе правки MEMORY.md в workspace не попадут в авто-загрузку qwen.
#
# Платформа: macOS (POSIX). Только нативный симлинк: копия запрещена — она
# тихо расходится с оригиналом и ломает единый каталог памяти.
#
# Каталог памяти Qwen (по исходникам qwen-code v0.27.2, packages/core/src/memory/paths.ts):
#   база:  QWEN_CODE_MEMORY_BASE_DIR → QWEN_RUNTIME_DIR → QWEN_HOME → ~/.qwen
#   проект: санитизация пути БЕЗ приведения к нижнему регистру на posix
#           (packages/core/src/utils/paths.ts:388): каждый символ вне [A-Za-z0-9] → '-'
#           /Users/Alice/IWE → -Users-Alice-IWE
#   корень: по умолчанию — ближайший предок с .git; QWEN_CODE_MEMORY_PROJECT_SCOPE=workspace
#           — сам workspace. QWEN_CODE_MEMORY_LOCAL=1 несовместим с внешней памятью.
#
# Запуск:
#   bash scripts/link-memory.sh                 # workspace = $IWE_ROOT или ~/IWE
#   bash scripts/link-memory.sh --workspace DIR
#   bash scripts/link-memory.sh --force         # заменить копию ссылкой (с бэкапом)
#   bash scripts/link-memory.sh --print-id      # только id проекта памяти Qwen
#   bash scripts/link-memory.sh --print-target  # только каталог памяти Qwen
#
# --print-id/--print-target нужны setup-offline.sh, update.sh и restore-from-exocortex.sh
# (правило A14 адаптера): формула каталога памяти живёт только здесь.
#
set -euo pipefail

WORKSPACE_DIR="${IWE_ROOT:-${IWE_WORKSPACE:-$HOME/IWE}}"
FORCE=false
PRINT_TARGET=false
PRINT_ID=false
while [ $# -gt 0 ]; do
  case "$1" in
    --workspace) WORKSPACE_DIR="$2"; shift 2 ;;
    --force)     FORCE=true; shift ;;
    --print-target) PRINT_TARGET=true; shift ;;
    --print-id)  PRINT_ID=true; shift ;;
    --help|-h)   sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
  esac
done
WORKSPACE_DIR="${WORKSPACE_DIR/#\~/$HOME}"
# Нормализуем путь без хвостового слэша (кроме корня).
case "$WORKSPACE_DIR" in
  /) ;;
  */) WORKSPACE_DIR="${WORKSPACE_DIR%/}" ;;
esac
# Канонический путь: Qwen разрешает cwd через realpathSync (settings.ts) и
# realpathNearestExisting (memory/paths.ts). Без этого /tmp/... и /private/tmp/...
# дают разные id, и память «теряется» (на macOS /tmp — симлинк).
if [ -d "$WORKSPACE_DIR" ]; then
  WORKSPACE_DIR="$(cd -P -- "$WORKSPACE_DIR" 2>/dev/null && pwd -P)" || true
fi

if [ "${QWEN_CODE_MEMORY_LOCAL:-}" = "1" ]; then
  echo "❌ QWEN_CODE_MEMORY_LOCAL=1 держит память внутри <project>/.qwen/memory и" >&2
  echo "   несовместим со схемой этой ветки (единый каталог памяти в workspace)." >&2
  echo "   Убери переменную из окружения и повтори." >&2
  exit 1
fi

# --- Корень проекта памяти: ближайший предок с .git, если не задан scope=workspace ---
memory_project_root() {
  local dir="$1" scope
  scope="$(printf '%s' "${QWEN_CODE_MEMORY_PROJECT_SCOPE:-}" | tr '[:upper:]' '[:lower:]')"
  if [ "$scope" = "workspace" ]; then
    printf '%s\n' "$dir"
    return 0
  fi
  local cur="$dir"
  while [ "$cur" != "/" ]; do
    if [ -e "$cur/.git" ]; then
      printf '%s\n' "$cur"
      return 0
    fi
    cur="$(dirname "$cur")"
  done
  printf '%s\n' "$dir"
}

# --- Формула id: копия sanitizeCwd (posix, регистр сохраняется) ---
project_id_for() {
  local root="$1"
  printf '%s' "$root" | sed 's/[^a-zA-Z0-9]/-/g'
}

MEMORY_PROJECT_ROOT="$(memory_project_root "$WORKSPACE_DIR")"
QWEN_PROJECT_ID="$(project_id_for "$MEMORY_PROJECT_ROOT")"
QWEN_BASE_DIR="${QWEN_CODE_MEMORY_BASE_DIR:-${QWEN_RUNTIME_DIR:-${QWEN_HOME:-$HOME/.qwen}}}"
# База тоже канонизируется (Qwen разрешает пути через realpath): при HOME=/tmp/...
# иначе ссылка ведёт в /tmp/..., а restore ожидает /private/tmp/... и пересоздаёт её.
if [ -d "$QWEN_BASE_DIR" ]; then
  QWEN_BASE_DIR="$(cd -P -- "$QWEN_BASE_DIR" 2>/dev/null && pwd -P)" || true
fi
TARGET="$QWEN_BASE_DIR/projects/$QWEN_PROJECT_ID/memory"
LINK="$WORKSPACE_DIR/memory"

if $PRINT_ID; then printf '%s\n' "$QWEN_PROJECT_ID"; exit 0; fi
if $PRINT_TARGET; then printf '%s\n' "$TARGET"; exit 0; fi

echo "Workspace: $WORKSPACE_DIR"
echo "Project:   $MEMORY_PROJECT_ROOT (id: $QWEN_PROJECT_ID)"
echo "Link:      $LINK"
echo "Target:    $TARGET"

mkdir -p "$TARGET"

# Уже корректная ссылка на нужный каталог — выходим.
if [ -L "$LINK" ]; then
  current="$(readlink "$LINK")"
  if [ "$current" = "$TARGET" ]; then
    echo "✓ Симлинк уже корректен — ничего не делаю."
    exit 0
  fi
  echo "⚠ Симлинк ведёт в $current, ожидался $TARGET."
  if ! $FORCE; then
    echo "  Запусти с --force, чтобы пересоздать." >&2
    exit 2
  fi
  rm "$LINK"
fi

# Существующая реальная папка: слить в TARGET, сделать бэкап, только потом удалить.
if [ -e "$LINK" ] && [ ! -L "$LINK" ]; then
  if ! $FORCE; then
    echo "⚠ $LINK уже существует (вероятно, каталог-копия). Запусти с --force," >&2
    echo "  чтобы заменить ссылкой: содержимое сначала сольётся в ${TARGET}," >&2
    echo "  исходный каталог сохранится как memory.bak-<дата>." >&2
    exit 2
  fi
  backup="${LINK}.bak-$(date +%Y%m%d-%H%M%S)"
  echo "  Сливаю содержимое в $TARGET (cp -n, без перезатирания)..."
  (cd "$LINK" && find . -type d -print0 | while IFS= read -r -d '' d; do mkdir -p "$TARGET/$d"; done
   cd "$LINK" && find . -type f -print0 | while IFS= read -r -d '' f; do
     if [ ! -e "$TARGET/$f" ]; then cp "$f" "$TARGET/$f"; fi
   done)
  echo "  Сохраняю исходный каталог: $backup"
  mv "$LINK" "$backup"
fi

# Нативный симлинк — единственный поддерживаемый путь на macOS.
ln -s "$TARGET" "$LINK"
if [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$TARGET" ]; then
  echo "✓ Создан симлинк: $LINK → $TARGET"
else
  echo "❌ Не удалось создать симлинк $LINK → $TARGET" >&2
  exit 1
fi
