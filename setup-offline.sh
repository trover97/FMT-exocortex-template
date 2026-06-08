#!/bin/bash
# setup-offline.sh — установка IWE-шаблона под Qwen Code на Windows (git bash), offline.
#
# МОДЕЛЬ УСТАНОВКИ (важно):
#   Оригинальный setup.sh (macOS) разворачивает файлы из FMT-репо в РОДИТЕЛЬСКУЮ
#   workspace-папку и связывает их симлинками + переменными в ~/.zshenv.
#   На Windows симлинки (ln -s в git bash) ненадёжны, а оболочка — bash, не zsh.
#   Поэтому здесь workspace = САМ распакованный каталог: ты запускаешь `qwen`
#   прямо в нём. Никаких симлинков и копий в родителя — всё самодостаточно.
#   Хуки IWE сами резолвят корень через IWE_ROOT (этот скрипт его выставит).
#
# Чем отличается от setup.sh:
#   - НЕ требует интернета (нет cloud-проверок, MCP/OAuth, gh/curl).
#   - НЕ ставит планировщик (launchd/cron/systemd) — задачи запускаются вручную.
#   - git bash (GNU sed), без macOS-конструкций и симлинков.
#   - Подставляет плейсхолдеры {{...}} прямо в каталоге (in-place).
#   - Выставляет IWE_ROOT в ~/.bashrc (чтобы хуки нашли корень).
#
# Запуск (один раз после распаковки ZIP, ИЗ каталога репозитория):
#   cd <распакованный-каталог>
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
    --help|-h) sed -n '2,33p' "$0"; exit 0 ;;
  esac
done

# --- GNU sed (git bash) ---
if ! sed --version >/dev/null 2>&1; then
  echo "ОШИБКА: нужен GNU sed (он есть в git bash). BSD/macOS sed не поддерживается." >&2
  exit 1
fi
sed_inplace() { sed -i "$@"; }

echo "=== IWE offline setup (Qwen Code / Windows / git bash) ==="
echo "Каталог установки (= workspace = IWE_ROOT): $SCRIPT_DIR"
echo

# --- Параметры ---
# workspace = сам каталог (single-dir модель, надёжно на Windows)
WORKSPACE_DIR="$SCRIPT_DIR"
HOME_DIR="$HOME"
if $AUTO_YES; then
  GOVERNANCE_REPO="DS-strategy"
  ECOSYSTEM_REPO="DS-ecosystem-development"
  GITHUB_USER="local"
else
  read -rp "Governance-репо (личный хаб) [DS-strategy]: " GOVERNANCE_REPO
  GOVERNANCE_REPO="${GOVERNANCE_REPO:-DS-strategy}"
  read -rp "Ecosystem-репо (командное) [DS-ecosystem-development]: " ECOSYSTEM_REPO
  ECOSYSTEM_REPO="${ECOSYSTEM_REPO:-DS-ecosystem-development}"
  read -rp "GitHub username (offline — можно 'local') [local]: " GITHUB_USER
  GITHUB_USER="${GITHUB_USER:-local}"
fi

STRATEGY_REPO="$GOVERNANCE_REPO"
IWE_TEMPLATE_PATH="$SCRIPT_DIR"
IWE_RUNTIME_PATH="$SCRIPT_DIR/.iwe-runtime"
CLAUDE_PROJECT_SLUG="$(echo "$WORKSPACE_DIR" | tr '/' '-')"

# Путь к qwen CLI (для подстановки {{CLAUDE_PATH}} в скриптах ролей)
QWEN_PATH="$(command -v qwen 2>/dev/null || echo 'qwen')"

echo
echo "  Workspace / IWE_ROOT: $WORKSPACE_DIR"
echo "  Home:                 $HOME_DIR"
echo "  Governance repo:      $GOVERNANCE_REPO"
echo "  Ecosystem repo:       $ECOSYSTEM_REPO"
echo "  qwen CLI:             $QWEN_PATH"
echo

if ! $AUTO_YES && ! $DRY_RUN; then
  read -rp "Продолжить установку? (y/n) " ans
  case "$ans" in y|Y) ;; *) echo "Отменено."; exit 0 ;; esac
fi

# --- 1. Подстановка плейсхолдеров (in-place) ---
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
  "CLAUDE_PATH=$QWEN_PATH"
)

echo "[1/3] Подстановка плейсхолдеров..."
# ВАЖНО: после распаковки ZIP каталог НЕ является git-репо (.git отсутствует),
# поэтому перечисляем файлы через find, а не git ls-files.
COUNT=0
while IFS= read -r -d '' f; do
  grep -q '{{' "$f" 2>/dev/null || continue
  if $DRY_RUN; then echo "  [dry-run] ${f#$SCRIPT_DIR/}"; COUNT=$((COUNT+1)); continue; fi
  for pair in "${MAPPING[@]}"; do
    key="${pair%%=*}"; val="${pair#*=}"; val_escaped="${val//|/\\|}"
    sed_inplace "s|{{${key}}}|${val_escaped}|g" "$f"
  done
  COUNT=$((COUNT+1))
done < <(find "$SCRIPT_DIR" \
           \( -path '*/.git' -o -path '*/.git/*' \) -prune -o \
           -type f \( -name '*.sh' -o -name '*.py' -o -name '*.yaml' -o -name '*.yml' -o -name '*.json' -o -name '*.md' \) -print0)
echo "  Обработано файлов с плейсхолдерами: $COUNT"

# --- 2. IWE_ROOT в ~/.bashrc (чтобы хуки нашли корень) ---
# Хуки используют IWE_ROOT="${IWE_ROOT:-$HOME/IWE}". Если каталог не ~/IWE —
# пропишем явный экспорт (идемпотентно).
echo "[2/3] Настройка IWE_ROOT в ~/.bashrc..."
BASHRC="$HOME/.bashrc"
EXPORT_LINE="export IWE_ROOT=\"$WORKSPACE_DIR\""
if $DRY_RUN; then
  echo "  [dry-run] добавил бы в $BASHRC: $EXPORT_LINE"
elif [ "$WORKSPACE_DIR" = "$HOME/IWE" ]; then
  echo "  Каталог = ~/IWE → IWE_ROOT и так корректен (fallback). Пропуск."
else
  touch "$BASHRC"
  # удалить прежнюю строку IWE_ROOT (идемпотентность), затем добавить
  sed_inplace '/^export IWE_ROOT=/d' "$BASHRC" 2>/dev/null || true
  printf '%s\n' "$EXPORT_LINE" >> "$BASHRC"
  echo "  Добавлено в $BASHRC: $EXPORT_LINE"
  echo "  (применится в новых git bash; сейчас: source ~/.bashrc)"
fi

# --- 3. git pre-commit гейт платформенной совместимости ---
echo "[3/3] Включение git-хуков..."
if [ -d "$SCRIPT_DIR/.githooks" ] && ! $DRY_RUN; then
  git -C "$SCRIPT_DIR" config core.hooksPath .githooks 2>/dev/null \
    && echo "  Pre-commit hook включён (.githooks/)" || echo "  (git-репо не инициализирован — пропуск)"
fi

echo
echo "=== Готово ==="
echo "Дальше:"
echo "  1. source ~/.bashrc           # подхватить IWE_ROOT (или открой новый git bash)"
echo "  2. cd \"$WORKSPACE_DIR\""
echo "  3. qwen                       # запустить агента ЗДЕСЬ (это и есть workspace)"
echo
echo "Заметки:"
echo "  - Задачи по расписанию запускаются ВРУЧНУЮ → MANUAL-JOBS.md"
echo "  - Облачное (MCP, Telegram, Calendar, авто-обновление) отключено (offline)."
echo "  - Свои знания (архив РП, паки) держи в этом же каталоге или соседних — см. MIGRATION.md"
