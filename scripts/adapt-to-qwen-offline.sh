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
MANUAL-JOBS.md|MIGRATION.md|UPDATE.md|scripts/adapt-to-qwen-offline.sh|\
update-manifest.local.json"
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
  # Авторские пути → плейсхолдеры (на случай утечки в QWEN.md/seed).
  # Paths come from the environment, never a literal: a hardcoded home path would
  # make this sanitizer itself leak it, and the template validator ("no /Users/"
  # check, staged mode since v0.38.0) blocks the commit on it.
  # Override via IWE_AUTHOR_WS / IWE_AUTHOR_HOME when workspace is not $HOME/IWE.
  AUTHOR_WS="${IWE_AUTHOR_WS:-${HOME:-}/IWE}"
  AUTHOR_HOME="${IWE_AUTHOR_HOME:-${HOME:-}}"
  if [ -n "$AUTHOR_HOME" ]; then
    for f in QWEN.md seed/strategy/QWEN.md; do
      [ -f "$f" ] || continue
      # Longest first: workspace path contains the home path as a prefix.
      AWS="$AUTHOR_WS" AHOME="$AUTHOR_HOME" perl -i -pe '
        BEGIN { $ws = quotemeta($ENV{AWS}); $home = quotemeta($ENV{AHOME}); }
        s/$ws/{{WORKSPACE_DIR}}/g;
        s/$home/{{HOME_DIR}}/g;
      ' "$f"
    done
  fi
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
    if $DRY_RUN; then echo "  [dry-run] git show $SRC:$p > $p"; else git show "$SRC:$p" > "$p"; case "$p" in *.sh) chmod +x "$p" ;; esac; fi
    echo "  ✓ $p"
  else
    echo "  ⚠ $SRC:$p не найден — пропуск"
  fi
}
# Единый список «наших» файлов — используется и шагом 3 (восстановление),
# и шагом 7 (детектор дрейфа). Держать в одном месте, чтобы списки не разъезжались.
OWNED_FILES="
.qwen/settings.json
.mcp.json
update.sh
.gitattributes
.gitignore
setup-offline.sh
scripts/link-memory.sh
setup/install-iwe-paths.sh
MANUAL-JOBS.md
MIGRATION.md
UPDATE.md
scripts/adapt-to-qwen-offline.sh
.qwen/owned-baseline.tsv
update-manifest.local.json
"
for p in $OWNED_FILES; do
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

# A10 — setup-local-gateway: своя формулировка, типовой guard соврал бы про планировщик.
# Three independent blockers, none of them fixable by the user:
#   1. install needs the network (git clone + npm ci);
#   2. daemon and proxy talk over a unix socket — Node on Windows only does
#      named pipes (\\.\pipe\), so the -S check can never pass there;
#   3. the gateway arbitrates locks between SEVERAL agents; an offline install
#      runs a single one.
# Guard, not deletion: docs/AGENT-VENDOR-SETUP.md links the script and
# update-manifest.json lists it — removing the file would desync both.
SLG="setup/optional/setup-local-gateway.sh"
if [ -f "$SLG" ] && ! grep -qF "LOCAL-GATEWAY GUARD (qwen-windows-offline branch)" "$SLG"; then
  if ! $DRY_RUN; then
    perl -0777 -i -pe 's/(set -euo pipefail\n)/$1\n# === LOCAL-GATEWAY GUARD (qwen-windows-offline branch) ===\n# Шлюз недоступен в этой сборке по трём независимым причинам: установка требует\n# сети (git clone + npm ci); демон общается через unix-сокет, которого на Windows\n# нет (Node умеет только named pipes); координация нужна лишь при нескольких\n# агентах, а offline-установка одиночная. Удали блок, если условия изменились.\necho "Локальный шлюз координации агентов недоступен в сборке qwen-windows-offline:" >&2\necho "  установка требует интернета, а демон работает через unix-сокет, которого нет на Windows." >&2\necho "  Шлюз нужен только при нескольких агентах на одной машине — одиночной установке он не требуется." >&2\nexit 0\n# === \/LOCAL-GATEWAY GUARD ===\n\n/' "$SLG"
  fi
  echo "  ✓ A10 local-gateway guard → $SLG"
else
  echo "  ○ $SLG уже с guard или отсутствует"
fi

# A11 — user-owned files in the runtime builder: a CHECK, deliberately not an edit.
# The protection itself lives in setup/build-runtime.sh on main (ported wholesale from
# upstream, issues #327/#348) and arrives here with every regeneration. Re-inserting it
# from the adapter would make the branch a second source of truth for the same logic and
# let the two drift apart. If a future main ever loses the guard, params.yaml is
# overwritten on every install and the user's settings vanish without a word — hence a
# loud complaint here rather than a silently broken build.
BRT="setup/build-runtime.sh"
if [ ! -f "$BRT" ]; then
  echo "  ⚠ A11: $BRT отсутствует — проверить нечего" >&2
elif grep -q "is_protected_user_file" "$BRT"; then
  echo "  ✓ A11: защита пользовательских файлов на месте"
else
  echo "  ⚠ A11: в $BRT НЕТ функции is_protected_user_file." >&2
  echo "    Настройки пользователя (params.yaml, memory/MEMORY.md) будут затёрты" >&2
  echo "    при каждой установке. Почини main форка — перенеси файл из upstream/main," >&2
  echo "    затем пересобери ветку. Публиковать сборку в таком виде нельзя." >&2
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

# ---------------------------------------------------------------------------
# 6) Windows/offline нормализация (WP-25 Ф3) — идемпотентно
# ---------------------------------------------------------------------------
echo "[6] Windows/offline нормализация..."
if ! $DRY_RUN; then
  # A4: export IWE_WORKSPACE в bootstrap (day-open использует $IWE_WORKSPACE для репо-путей).
  BOOT=".qwen/lib/iwe-env-bootstrap.sh"
  if [ -f "$BOOT" ] && ! grep -q 'export IWE_WORKSPACE=' "$BOOT"; then
    perl -i -pe 's{^(export IWE_ROOT="\$\{IWE_ROOT:-\$WORKSPACE_DIR\}")$}{$1\nexport IWE_WORKSPACE="\$\{IWE_WORKSPACE:-\$WORKSPACE_DIR\}"}' "$BOOT"
    echo "  ✓ A4 IWE_WORKSPACE → $BOOT"
  else
    echo "  ○ A4 IWE_WORKSPACE уже есть / нет файла"
  fi

  # A3: ссылки на скрипты $IWE_WORKSPACE/scripts, {{WORKSPACE_DIR}}/scripts → $IWE_SCRIPTS
  #     (в offline-модели скрипты лежат в FMT-подпапке = $IWE_SCRIPTS, не в корне workspace).
  while IFS= read -r -d '' f; do
    perl -i -pe 's{\$IWE_WORKSPACE/scripts/}{\$IWE_SCRIPTS/}g; s{\{\{WORKSPACE_DIR\}\}/scripts/}{\$IWE_SCRIPTS/}g;' "$f"
  done < <(find .qwen/skills -name 'SKILL.md' -print0)
  echo "  ✓ A3 пути скриптов → \$IWE_SCRIPTS (SKILL.md)"

  # A5: day-open шаг 1b (gh issues / fmt-critical-alert) требует сети+gh → offline-пометка.
  DO=".qwen/skills/day-open/SKILL.md"
  if [ -f "$DO" ] && ! grep -qF 'OFFLINE: gh/сеть недоступны' "$DO"; then
    perl -i -pe 's{^(### 1b\. GitHub Issues)$}{$1\n> **OFFLINE: gh/сеть недоступны — шаг 1b пропустить** (нет gh CLI и интернета).}' "$DO"
    echo "  ✓ A5 gh offline-пометка → day-open"
  else
    echo "  ○ A5 пометка уже есть / нет файла"
  fi

  # A6: day-open не звать update.sh --check daily (offline: обновления вручную по UPDATE.md;
  #     хэширование сотен файлов через shasum-subprocess медленно в git bash Windows).
  if [ -f "$DO" ]; then
    perl -i -pe 's{`cd "\$IWE_TEMPLATE" && bash update\.sh --check 2>&1`}{(offline) обновления приходят вручную (распаковка ZIP, см. `UPDATE.md`); ежедневная `update.sh --check` пропускается}g' "$DO"
    echo "  ✓ A6 update.sh --check убран из daily day-open"
  fi

  # A7: обёртка top-level {"additionalContext":…} → {"hookSpecificOutput":{hookEventName,additionalContext}}.
  #     Qwen Code для UserPromptSubmit/PostToolUse инъектит контекст через hookSpecificOutput.additionalContext;
  #     top-level поле additionalContext вне hookSpecificOutput может игнорироваться (в Claude Code работает — не наш случай).
  #     Событие берётся из строки заголовка "# Event: <Name>". Идемпотентно (skip если уже hookSpecificOutput).
  wrap_ac() {
    local f="$1"
    [ -f "$f" ] || { echo "  ○ A7 нет файла $f"; return; }
    grep -q 'hookSpecificOutput' "$f" && { echo "  ○ A7 $f уже обёрнут"; return; }
    local ev
    ev=$(grep -m1 '^# Event:' "$f" | sed -E 's/^# Event:[[:space:]]*([A-Za-z]+).*/\1/')
    [ -n "$ev" ] || ev="UserPromptSubmit"
    perl -i -pe 'BEGIN{$e=shift} s/^\{"additionalContext": (.*)\}[ \t]*$/{"hookSpecificOutput": {"hookEventName": "$e", "additionalContext": $1}}/' "$ev" "$f"
    echo "  ✓ A7 additionalContext → hookSpecificOutput ($ev) в $f"
  }
  for h in wp-gate-reminder close-gate-reminder protocol-completion-reminder; do
    wrap_ac ".qwen/hooks/$h.sh"
  done

  # A8: резолв WORKSPACE_DIR через $QWEN_PROJECT_DIR (WP-25, найдено 27.07).
  #     Хуки берут корень workspace как "${WORKSPACE_DIR:-$HOME/IWE}". На Windows workspace
  #     обычно лежит ВНЕ $HOME (C:/Work/IWE при $HOME=/c/Users/<user>), а WORKSPACE_DIR
  #     хукам никто не экспортирует (iwe-env-bootstrap.sh хуки не подключают) → путь не
  #     совпадает и хук молча выходит (все они exit 0 by design). На macOS не воспроизводится:
  #     там workspace == $HOME/IWE. QWEN_PROJECT_DIR выставляет сам Qwen Code = корень
  #     workspace (в settings.json по нему резолвятся все пути хуков). Идемпотентно.
  ws_fallback() {
    local f="$1"
    [ -f "$f" ] || { echo "  ○ A8 нет файла $f"; return; }
    grep -q 'WORKSPACE_DIR:-\$HOME/IWE' "$f" || { echo "  ○ A8 $f уже резолвит / нет паттерна"; return; }
    perl -i -pe 's{\$\{WORKSPACE_DIR:-\$HOME/IWE\}}{\$\{WORKSPACE_DIR:-\$\{QWEN_PROJECT_DIR:-\$HOME/IWE\}\}}g' "$f"
    echo "  ✓ A8 WORKSPACE_DIR → \$QWEN_PROJECT_DIR fallback в $f"
  }
  #     Область — только .qwen/hooks: QWEN_PROJECT_DIR гарантированно выставлен лишь для
  #     хук-субпроцессов, которые порождает Qwen Code. Скрипты в scripts/ пользователь
  #     запускает из терминала, где этой переменной нет → там правило было бы холостым
  #     (их лечение — подключение iwe-env-bootstrap.sh, отдельный разбор).
  while IFS= read -r h; do
    ws_fallback "$h"
  done < <(grep -rl 'WORKSPACE_DIR:-\$HOME/IWE' .qwen/hooks 2>/dev/null)

  # A9: та же задача, что A7 (top-level additionalContext → hookSpecificOutput), но для
  #     lazy-context-loader: он собирает ответ внутри python-heredoc через json.dumps,
  #     а не отдаёт готовой JSON-строкой, поэтому построчное правило A7 его не ловит.
  #     Идемпотентно (skip если уже hookSpecificOutput).
  LCL=".qwen/hooks/lazy-context-loader.sh"
  if [ -f "$LCL" ] && ! grep -q 'hookSpecificOutput' "$LCL"; then
    perl -i -pe "s/json\.dumps\(\{'additionalContext': (.*)\}\)/json.dumps({'hookSpecificOutput': {'hookEventName': 'UserPromptSubmit', 'additionalContext': \$1}})/" "$LCL"
    echo "  ✓ A9 additionalContext → hookSpecificOutput (UserPromptSubmit) в $LCL"
  else
    echo "  ○ A9 $LCL уже обёрнут / нет файла"
  fi
fi
echo "  ✓"


# ---------------------------------------------------------------------------
# 7) Детектор дрейфа «наших» файлов (WP-25, 27.07)
# ---------------------------------------------------------------------------
# ЗАЧЕМ: шаг 3 восстанавливает «наши» файлы ДОСЛОВНО — апстрим-правки в них теряются
# целиком. Для чисто форковых файлов (setup-offline.sh, UPDATE.md, этот скрипт и др.)
# это правильно: в шаблоне их нет. Но часть файлов смешанной природы — форковая политика
# плюс содержимое, которое живёт и развивается в шаблоне (.qwen/settings.json — список
# подключённых хуков; update.sh; .gitignore). Для них дословное восстановление молча
# откатывает апстрим.
#
# UPDATE.md («Если upstream сломал наш файл») предписывает сверяться с main вручную после
# каждой регенерации, но ручной шаг ничем не запускается — за 3 цикла его не выполнили ни
# разу, и расхождение копилось незаметно: так был потерян хук memory-exocortex-sync
# (подключён в шаблоне с v0.35.4, до ветки не доехал) — см. A8.
#
# Этот шаг не чинит и не мержит — он делает потерю ВИДИМОЙ: показывает апстрим-коммиты,
# которые мы в свою версию файла ещё не сверяли. Решение о переносе принимает мейнтейнер.
# Только чтение, на результат регенерации не влияет.
#
# ЯКОРЬ — реестр .qwen/owned-baseline.tsv (строки «<наш файл>\t<SHA main>»): до какого
# коммита шаблона файл сверён. По датам это НЕ определяется: регенерация переписывает все
# файлы разом, поэтому «дата последнего изменения в ветке» = дата последней регенерации,
# а не дата, когда содержимое действительно писали (первая версия этого детектора на такой
# эвристике давала ложное «дрейфа нет»).
#
# ПОРЯДОК РАБОТЫ: перенёс апстрим-правку в свою версию (или осознанно отказался) →
# обнови SHA в реестре на текущий main. Пока SHA старый, файл будет в отчёте.
echo
echo "[7] Дрейф «наших» файлов (апстрим-правки, которые не сверены)..."
MAIN_REF="${MAIN_REF:-origin/main}"
git rev-parse --verify -q "$MAIN_REF" >/dev/null 2>&1 || MAIN_REF="HEAD"
BASELINE_FILE=".qwen/owned-baseline.tsv"

drift_files=0
drift_commits=0
for bp in $OWNED_FILES; do
  # Соответствие в шаблоне: тот же путь, но .qwen → .claude (расходится только settings.json).
  mp="${bp/#.qwen\//.claude/}"
  # Нет в шаблоне → файл чисто форковый, дословное восстановление правомерно.
  git cat-file -e "$MAIN_REF:$mp" 2>/dev/null || continue

  base=""
  [ -f "$BASELINE_FILE" ] && base=$(awk -F'\t' -v f="$bp" '$1==f{print $2; exit}' "$BASELINE_FILE")
  if [ -z "$base" ] || ! git rev-parse --verify -q "$base" >/dev/null 2>&1; then
    echo "  ? $bp — нет отметки сверки в $BASELINE_FILE (добавь строку «$bp<TAB><SHA main>»)"
    drift_files=$((drift_files + 1))
    continue
  fi

  n=$(git log --oneline "$base..$MAIN_REF" -- "$mp" 2>/dev/null | wc -l | tr -d ' ')
  [ "${n:-0}" -gt 0 ] 2>/dev/null || continue
  drift_files=$((drift_files + 1))
  drift_commits=$((drift_commits + n))
  echo "  ⚠ $bp — $n апстрим-коммит(ов) в $mp после сверенного ${base:0:7}:"
  git log --format='      %h %s' "$base..$MAIN_REF" -- "$mp" 2>/dev/null | head -5
  [ "$n" -gt 5 ] && echo "      … ещё $((n - 5))"
done

if [ "$drift_files" -eq 0 ]; then
  echo "  ✓ дрейфа нет — «наши» файлы сверены с текущим шаблоном"
else
  echo "  → $drift_files файл(ов), $drift_commits несверенных коммит(ов). Это НЕ ошибка"
  echo "    регенерации: решить по каждому, переносить ли правку (UPDATE.md, раздел"
  echo "    «Если upstream сломал наш файл»). Сверка: git diff $MAIN_REF -- <файл>"
  echo "    Сверил → обнови SHA в $BASELINE_FILE."
fi

echo
echo "=== Готово. Проверь git status / git diff, затем закоммить. ==="
echo "Полный цикл обновления — UPDATE.md."
