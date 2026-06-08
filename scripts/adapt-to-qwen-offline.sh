#!/bin/bash
# adapt-to-qwen-offline.sh — детерминированно превращает свежий main
# (обновлённый из upstream) в ветку qwen-windows-offline.
#
# ЗАЧЕМ: наша адаптация на ~95% механическая (переименования + строковая замена
# .claude→.qwen) + набор полностью «наших» файлов. Поэтому обновляться через
# `git merge main` = постоянные конфликты. Вместо этого мы РЕГЕНЕРИРУЕМ ветку:
# берём чистый main и заново прогоняем адаптацию. Конфликтов нет.
#
# ИСПОЛЬЗОВАНИЕ (полный цикл обновления — см. UPDATE.md):
#   git fetch origin
#   git checkout -B qwen-next origin/main         # свежий main из upstream
#   git show origin/qwen-windows-offline:scripts/adapt-to-qwen-offline.sh > /tmp/adapt.sh
#   bash /tmp/adapt.sh --src origin/qwen-windows-offline
#   git add -A && git commit -m "regen qwen-windows-offline from main vX.Y.Z"
#   # проверить, затем: git branch -f qwen-windows-offline qwen-next && git push -f? (см. UPDATE.md)
#
# Аргументы:
#   --src REF   git-ref предыдущей ветки qwen (источник «наших» файлов).
#               default: origin/qwen-windows-offline (fallback: qwen-windows-offline)
#   --dry-run   показать действия без изменений
#
set -euo pipefail

SRC="origin/qwen-windows-offline"
DRY_RUN=false
while [ $# -gt 0 ]; do
  case "$1" in
    --src)     SRC="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --help|-h) sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
  esac
done

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "Не git-репозиторий" >&2; exit 1; }
if ! git rev-parse --verify "$SRC" >/dev/null 2>&1; then
  SRC="qwen-windows-offline"
  git rev-parse --verify "$SRC" >/dev/null 2>&1 || { echo "Не найден src-ref ветки qwen" >&2; exit 1; }
fi
echo "=== adapt-to-qwen-offline (src=$SRC, dry-run=$DRY_RUN) ==="

run() { if $DRY_RUN; then echo "  [dry-run] $*"; else eval "$@"; fi; }

# ---------------------------------------------------------------------------
# 1) Переименования (если источник существует)
# ---------------------------------------------------------------------------
echo "[1] Переименования..."
do_mv() { [ -e "$1" ] && { run "git mv -f \"$1\" \"$2\""; echo "  $1 → $2"; } || true; }
do_mv CLAUDE.md QWEN.md
[ -d .claude ] && { run "git mv -f .claude .qwen"; echo "  .claude → .qwen"; } || true
do_mv seed/strategy/CLAUDE.md seed/strategy/QWEN.md
do_mv templates/strategy-skeleton/CLAUDE.md templates/strategy-skeleton/QWEN.md

# ---------------------------------------------------------------------------
# 2) Строковые замены (URL-safe), кроме CHANGELOG и «наших» файлов
# ---------------------------------------------------------------------------
echo "[2] Строковые замены .claude→.qwen, CLAUDE→QWEN..."
# OWNED восстанавливаются ниже шагом 3 — их перловка не трогает (исключаем).
OWNED="\
.qwen/settings.json|.mcp.json|update.sh|.gitattributes|.gitignore|\
setup-offline.sh|scripts/link-memory.sh|setup/install-iwe-paths.sh|\
MANUAL-JOBS.md|MIGRATION.md|UPDATE.md|scripts/adapt-to-qwen-offline.sh"
if ! $DRY_RUN; then
  while IFS= read -r -d '' f; do
    case "$f" in
      *CHANGELOG.md) continue ;;
    esac
    rel="${f#./}"
    echo "$rel" | grep -qE "^(${OWNED})$" && continue
    perl -i -pe '
      s/CLAUDE_PROJECT_DIR/QWEN_PROJECT_DIR/g;
      s/\.claude\//.qwen\//g;
      s/\.claude(?![\w.])/.qwen/g;
      s/CLAUDE\.md/QWEN.md/g;
      s/Claude Code/Qwen Code/g;
    ' "$f"
  done < <(find . \( -path './.git' -o -path './.git/*' \) -prune -o \
             -type f \( -name '*.sh' -o -name '*.py' -o -name '*.yaml' -o -name '*.yml' -o -name '*.json' -o -name '*.md' \) -print0)
  # Авторские пути → плейсхолдеры (на случай утечки в QWEN.md/seed)
  for f in QWEN.md seed/strategy/QWEN.md; do
    [ -f "$f" ] && perl -i -pe 's{/Users/avlakriv/IWE}{{{WORKSPACE_DIR}}}g; s{/Users/avlakriv}{{{HOME_DIR}}}g;' "$f"
  done
fi
echo "  ✓"

# ---------------------------------------------------------------------------
# 3) «Наши» файлы — восстановить дословно из ветки qwen ($SRC)
# ---------------------------------------------------------------------------
echo "[3] Восстановление наших файлов из $SRC..."
restore() {
  local p="$1"
  if git cat-file -e "$SRC:$p" 2>/dev/null; then
    run "mkdir -p \"\$(dirname \"$p\")\""
    if $DRY_RUN; then echo "  [dry-run] git show $SRC:$p > $p"; else git show "$SRC:$p" > "$p"; fi
    echo "  ✓ $p"
  else
    echo "  ⚠ $SRC:$p не найден — пропуск"
  fi
}
for p in .qwen/settings.json .mcp.json update.sh .gitattributes .gitignore \
         setup-offline.sh scripts/link-memory.sh setup/install-iwe-paths.sh \
         MANUAL-JOBS.md MIGRATION.md UPDATE.md scripts/adapt-to-qwen-offline.sh; do
  restore "$p"
done

# ---------------------------------------------------------------------------
# 4) Guard «нет планировщика» — вставить после shebang, если маркера ещё нет
# ---------------------------------------------------------------------------
echo "[4] Guard'ы offline/no-scheduler..."
GUARD_MARK="OFFLINE / NO-SCHEDULER GUARD (qwen-windows-offline)"
GUARD_FILE="$(mktemp)"
cat > "$GUARD_FILE" <<'GB'
# === OFFLINE / NO-SCHEDULER GUARD (qwen-windows-offline) ===
# Эта ветка: Windows + git bash, без планировщика (launchd/cron/systemd).
# Установка задач по расписанию невозможна. Рабочие скрипты роли запускаются
# ВРУЧНУЮ — см. MANUAL-JOBS.md в корне репозитория.
echo "[$(basename "$(dirname "$0")")] Планировщик недоступен (offline/Windows). Запуск задач — вручную, см. MANUAL-JOBS.md" >&2
exit 0
# === /GUARD ===
GB
# Портируемо: awk читает блок из файла (getline), без многострочных -v.
insert_after_shebang() {
  local f="$1" mark="$2"
  [ -f "$f" ] || { echo "  ○ $f нет — пропуск"; return; }
  grep -qF "$mark" "$f" && { echo "  ○ $f уже с guard"; return; }
  if $DRY_RUN; then echo "  [dry-run] guard → $f"; return; fi
  awk -v bf="$GUARD_FILE" 'NR==1{print; while((getline l < bf)>0) print l; close(bf); next} {print}' "$f" > "$f.tmp" \
    && mv "$f.tmp" "$f" && chmod +x "$f"
  echo "  ✓ guard → $f"
}
for f in roles/extractor/install.sh roles/strategist/install.sh roles/synchronizer/install.sh \
         setup/optional/setup-cloud-scheduler.sh setup/optional/setup-calendar.sh \
         scripts/setup-extractor-feeders.sh scripts/server-calendar.sh scripts/server-news.sh; do
  insert_after_shebang "$f" "$GUARD_MARK"
done

# agent-trace-uploader: особый offline-guard (после set -uo pipefail)
ATU=".qwen/hooks/agent-trace-uploader.sh"
if [ -f "$ATU" ] && ! grep -qF "OFFLINE GUARD (qwen-windows-offline branch)" "$ATU"; then
  if ! $DRY_RUN; then
    perl -0777 -i -pe 's/(set -uo pipefail\n)/$1\n# === OFFLINE GUARD (qwen-windows-offline branch) ===\n# Эта ветка работает без интернета. Загрузка трейсов в облако невозможна.\n# Локальные NDJSON сохраняются на диске. Удали блок, чтобы включить загрузку.\necho "agent-trace-uploader: offline-режим — загрузка пропущена" >&2\nexit 0\n# === \/OFFLINE GUARD ===\n\n/' "$ATU"
  fi
  echo "  ✓ offline-guard → $ATU"
else
  echo "  ○ $ATU уже с guard или отсутствует"
fi

# ---------------------------------------------------------------------------
# 5) Вставные блоки README / QWEN.md (переносим из $SRC между маркерами)
# ---------------------------------------------------------------------------
echo "[5] Блоки README/QWEN..."
insert_block_after() {
  local file="$1" anchor="$2" begin="$3" end="$4" srcfile="$5"
  [ -f "$file" ] || { echo "  ○ $file нет — пропуск"; return; }
  grep -qF "$begin" "$file" && { echo "  ○ $file уже с блоком"; return; }
  local bf; bf="$(mktemp)"
  git show "$SRC:$srcfile" 2>/dev/null | awk -v b="$begin" -v e="$end" '$0~b{f=1} f{print} $0~e{f=0}' > "$bf"
  [ -s "$bf" ] || { echo "  ⚠ блок $begin не найден в $SRC:$srcfile"; rm -f "$bf"; return; }
  if $DRY_RUN; then echo "  [dry-run] блок → $file"; rm -f "$bf"; return; fi
  awk -v anc="$anchor" -v bf="$bf" '
    {print}
    !done && index($0,anc){print ""; while((getline l < bf)>0) print l; close(bf); done=1}
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  rm -f "$bf"
  echo "  ✓ блок → $file"
}
# README: вставить после первой строки "---"
insert_block_after README.md "---" "QWEN-OFFLINE:BEGIN" "QWEN-OFFLINE:END" README.md
# QWEN.md: вставить после H1
insert_block_after QWEN.md "# Инструкции для всех репозиториев" "QWEN-OFFLINE-ENV:BEGIN" "QWEN-OFFLINE-ENV:END" QWEN.md

echo
echo "=== Готово. Проверь git status / git diff, затем закоммить. ==="
echo "Полный цикл обновления — UPDATE.md."
