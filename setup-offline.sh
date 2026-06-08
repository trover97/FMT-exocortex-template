#!/bin/bash
# setup-offline.sh — установка IWE-шаблона под Qwen Code на Windows (git bash), offline.
#
# Чем отличается от оригинального setup.sh:
#   - НЕ требует интернета (нет cloud-проверок, нет MCP/OAuth, нет gh/curl).
#   - НЕ ставит планировщик (launchd/cron/systemd недоступны) — задачи запускаются вручную.
#   - Работает в git bash на Windows (GNU sed, без macOS-конструкций).
#   - Подставляет шаблонные плейсхолдеры {{...}} прямо в рабочей копии (in-place).
#
# Запуск (один раз после распаковки ZIP):
#   bash setup-offline.sh
#   bash setup-offline.sh --yes        # без подтверждений (значения по умолчанию)
#   bash setup-offline.sh --dry-run    # показать что будет сделано, без изменений
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUTO_YES=false
DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --yes)     AUTO_YES=true ;;
    --dry-run) DRY_RUN=true ;;
    --help|-h) sed -n '2,14p' "$0"; exit 0 ;;
  esac
done

# --- GNU sed (git bash) ---
if ! sed --version >/dev/null 2>&1; then
  echo "ОШИБКА: нужен GNU sed (он есть в git bash). BSD/macOS sed не поддерживается этим скриптом." >&2
  exit 1
fi
sed_inplace() { sed -i "$@"; }

echo "=== IWE offline setup (Qwen Code / Windows / git bash) ==="
echo

# --- Сбор параметров ---
DEFAULT_WORKSPACE="$(dirname "$SCRIPT_DIR")"
if $AUTO_YES; then
  WORKSPACE_DIR="$DEFAULT_WORKSPACE"
  GOVERNANCE_REPO="DS-strategy"
  ECOSYSTEM_REPO="DS-ecosystem-development"
  GITHUB_USER="local"
else
  read -rp "Рабочий каталог IWE (workspace) [$DEFAULT_WORKSPACE]: " WORKSPACE_DIR
  WORKSPACE_DIR="${WORKSPACE_DIR:-$DEFAULT_WORKSPACE}"
  read -rp "Governance-репо (личный хаб) [DS-strategy]: " GOVERNANCE_REPO
  GOVERNANCE_REPO="${GOVERNANCE_REPO:-DS-strategy}"
  read -rp "Ecosystem-репо (командное) [DS-ecosystem-development]: " ECOSYSTEM_REPO
  ECOSYSTEM_REPO="${ECOSYSTEM_REPO:-DS-ecosystem-development}"
  read -rp "GitHub username (offline — можно оставить 'local') [local]: " GITHUB_USER
  GITHUB_USER="${GITHUB_USER:-local}"
fi
WORKSPACE_DIR="${WORKSPACE_DIR/#\~/$HOME}"

HOME_DIR="$HOME"
STRATEGY_REPO="$GOVERNANCE_REPO"
IWE_TEMPLATE_PATH="$SCRIPT_DIR"
IWE_RUNTIME_PATH="$WORKSPACE_DIR/.iwe-runtime"
CLAUDE_PROJECT_SLUG="$(echo "$WORKSPACE_DIR" | tr '/' '-')"

echo
echo "  Workspace:       $WORKSPACE_DIR"
echo "  Home:            $HOME_DIR"
echo "  Governance repo: $GOVERNANCE_REPO"
echo "  Ecosystem repo:  $ECOSYSTEM_REPO"
echo "  Template path:   $IWE_TEMPLATE_PATH"
echo "  Runtime path:    $IWE_RUNTIME_PATH"
echo "  GitHub user:     $GITHUB_USER"
echo

if ! $AUTO_YES && ! $DRY_RUN; then
  read -rp "Продолжить подстановку плейсхолдеров? (y/n) " ans
  case "$ans" in y|Y) ;; *) echo "Отменено."; exit 0 ;; esac
fi

# --- Подстановка плейсхолдеров во все текстовые файлы ---
# {{X}} (иллюстративный пример в доках) намеренно НЕ трогаем.
MAPPING=(
  "WORKSPACE_DIR=$WORKSPACE_DIR"
  "HOME_DIR=$HOME_DIR"
  "GOVERNANCE_REPO=$GOVERNANCE_REPO"
  "STRATEGY_REPO=$STRATEGY_REPO"
  "ECOSYSTEM_REPO=$ECOSYSTEM_REPO"
  "GITHUB_USER=$GITHUB_USER"
  "IWE_TEMPLATE=$IWE_TEMPLATE_PATH"
  "IWE_RUNTIME=$IWE_RUNTIME_PATH"
  "CLAUDE_PROJECT_SLUG=$CLAUDE_PROJECT_SLUG"
)

FILES=$(cd "$SCRIPT_DIR" && git ls-files '*.sh' '*.py' '*.yaml' '*.yml' '*.json' '*.md' 2>/dev/null || true)
COUNT=0
for f in $FILES; do
  [ -f "$SCRIPT_DIR/$f" ] || continue
  grep -q '{{' "$SCRIPT_DIR/$f" 2>/dev/null || continue
  if $DRY_RUN; then
    echo "  [dry-run] подставил бы плейсхолдеры в: $f"
    COUNT=$((COUNT+1))
    continue
  fi
  for pair in "${MAPPING[@]}"; do
    key="${pair%%=*}"; val="${pair#*=}"
    val_escaped="${val//|/\\|}"
    sed_inplace "s|{{${key}}}|${val_escaped}|g" "$SCRIPT_DIR/$f"
  done
  COUNT=$((COUNT+1))
done
echo "  Обработано файлов с плейсхолдерами: $COUNT"

# --- git hooks (переносимый pre-commit гейт платформенной совместимости) ---
if [ -d "$SCRIPT_DIR/.githooks" ] && ! $DRY_RUN; then
  git -C "$SCRIPT_DIR" config core.hooksPath .githooks 2>/dev/null \
    && echo "  Pre-commit hook включён (.githooks/)" || true
fi

echo
echo "=== Готово ==="
echo "Дальше:"
echo "  1. Запусти Qwen Code в этом каталоге:  qwen"
echo "  2. Задачи по расписанию запускаются ВРУЧНУЮ — см. MANUAL-JOBS.md"
echo "  3. Облачные функции (MCP, Telegram, Calendar, авто-обновление) отключены (offline)."
