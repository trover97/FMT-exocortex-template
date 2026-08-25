#!/bin/bash
# Exocortex Update — OFFLINE-режим (ветка qwen-windows-offline / Qwen Code / Windows).
#
# Обновляет УЖЕ УСТАНОВЛЕННУЮ среду из обновлённого FMT-репо, СОХРАНЯЯ
# пользовательские данные (память, настройки, governance). В отличие от
# setup-offline.sh (первая установка) — update.sh идемпотентен и не затирает
# накопленное.
#
# === Как обновляться (offline, без GitHub) ===
#   1. На машине с сетью открой ветку qwen-windows-offline форка → «Code» → «Download ZIP».
#   2. Перенеси ZIP, распакуй. Замени папку FMT новой версией:
#        rm -rf ~/IWE/FMT-exocortex-template
#        cp -r /путь/к/распакованному ~/IWE/FMT-exocortex-template
#   3. Запусти отсюда:
#        cd ~/IWE/FMT-exocortex-template
#        bash update.sh --check     # превью без изменений
#        bash update.sh             # применить
#
# Модель: FMT-репо (где лежит этот скрипт) = ИСТОЧНИК новых файлов.
#         WORKSPACE (родительская папка) = установленная среда (приёмник).
#         setup-offline.sh = первая установка; update.sh = обновление.
#
# Что СОХРАНЯЕТСЯ (не перезаписывается):
#   memory/MEMORY.md, memory/day-rhythm-config.yaml, params.yaml,
#   .qwen/settings.local.json, DS-strategy/, extensions/.
# Перед записью в каталог памяти делается бэкап (<memory>.bak-<timestamp>).
#
# Использование:
#   bash update.sh              # превью + применение (с подтверждением)
#   bash update.sh --check      # только превью (alias --dry-run)
#   bash update.sh --yes        # применить без подтверждения
#   bash update.sh --version
#   bash update.sh --help
#
set -eo pipefail

VERSION="3.0.0-offline"   # offline-порт upstream update.sh Step 6 (WP-25)

CHECK_ONLY=false
AUTO_YES=false
for arg in "$@"; do
    case "$arg" in
        --check|--dry-run) CHECK_ONLY=true ;;
        --yes)             AUTO_YES=true ;;
        --version)         echo "exocortex-update (offline) v$VERSION"; exit 0 ;;
        --help|-h)         sed -n '2,33p' "$0"; exit 0 ;;
    esac
done

# === GNU sed (git bash) ===
if sed --version >/dev/null 2>&1; then
    sed_inplace() { sed -i "$@"; }
else
    sed_inplace() { sed -i '' "$@"; }
fi

# === Cross-platform hash ===
hash_file() {
    shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1 || \
    sha256sum "$1" 2>/dev/null | cut -d' ' -f1
}

# === Cross-platform Python resolution (upstream issue #402) ===
# On Windows Git Bash, `command -v python3` finds the Microsoft Store App Execution
# Alias stub (prints "Python was not found..." and exits non-zero) even when a real
# interpreter is installed and reachable as `python` — the python.org installer for
# Windows ships no `python3` shim. A presence check alone is not enough: probe that
# the candidate actually runs code. This branch targets exactly that platform, and
# `setup-offline.sh` seeds a `python3`→`python` PATH wrapper (rule A1) that the stub
# can still shadow depending on PATH order.
#
# PY_BIN is used UNQUOTED at call sites on purpose: the `py -3` candidate is two
# words, and "$PY_BIN" would look for a binary literally named "py -3". Do not add
# quotes here without collapsing that candidate first (upstream quotes it in one
# place and not in others — that inconsistency is a latent bug, not a model).
PY_BIN=""
for _py_candidate in python3 python; do
    if command -v "$_py_candidate" >/dev/null 2>&1 && "$_py_candidate" -c 'pass' >/dev/null 2>&1; then
        PY_BIN="$_py_candidate"
        break
    fi
done
if [ -z "$PY_BIN" ] && command -v py >/dev/null 2>&1 && py -3 -c 'pass' >/dev/null 2>&1; then
    PY_BIN="py -3"
fi
unset _py_candidate
py_available() { [ -n "$PY_BIN" ]; }

# Деградация до grep-разбора манифеста сообщается один раз за прогон, а не на файл
# (тот же приём, что у апстрима с классификатором пропусков). Без сообщения отказ
# был бы тихим: список устаревших файлов молча пустеет, чистка не выполняется.
PY_DEGRADED_WARNED=false
warn_py_degraded() {
    [ "$PY_DEGRADED_WARNED" = false ] || return 0
    PY_DEGRADED_WARNED=true
    echo "  ⚠ Разбор манифеста через Python не удался (проверены python3, python, py -3)." >&2
    echo "    Список файлов собран запасным способом (grep), список снятых с поставки файлов недоступен —" >&2
    echo "    удаление устаревших файлов в этом прогоне не выполнится." >&2
}

# === Личные L4-конфиги в памяти: сеять при отсутствии, НИКОГДА не перезаписывать ===
# (персональные правки — calendar_ids, slot-настройки). MEMORY.md защищён отдельно.
is_personal_config() {
    case "$1" in
        day-rhythm-config.yaml) return 0 ;;
        *) return 1 ;;
    esac
}

# === owner: user в memory-файлах — пилот владеет файлом, не перезаписываем (upstream #229) ===
# Порт из шаблона. Раньше защищались только MEMORY.md и day-rhythm-config.yaml, а ветка
# несёт 13 файлов памяти с owner: user — их обновление молча затирало правки пилота.
# Читатель frontmatter (.qwen/lib/frontmatter.sh) подключается ниже, после SCRIPT_DIR.

# Исключение из защиты (upstream #354/#384): эти файлы ведёт платформа, но старые релизы
# шаблона поставляли их с owner: user. Legacy-маркер не должен навсегда заморозить
# платформенные правки. Список точный и совпадает с шаблоном: личный стиль, авторские
# различения, снимки FPF и прочая настоящая память пилота остаются защищены.
# roles.md исключён из списка (upstream #470): файл несёт каталог ролей платформы ВМЕСТЕ
# с авторским разделом пользователя (личные роли, нумерация от R400) — блайнд-миграция
# стирала пользовательский раздел без предупреждения. Теперь под обычной защитой owner:user.
is_migrated_platform_memory_path() {
    case "$1" in
        memory/protocol-open.md|memory/protocol-work.md|memory/protocol-close.md|memory/protocol-month-close.md|\
        memory/agent-architecture-framework.md|memory/agent-vendor-connect-pattern.md|memory/checklists.md|\
        memory/dry-run-contract.md|memory/feedback_response_clarity_for_pilot.md|memory/hooks-design.md|\
        memory/navigation.md|memory/reference/agent-core.md|memory/repo-type-rules.md|\
        memory/r-questionnaire.md|memory/t-checklist.md|memory/templates-dayplan.md) return 0 ;;
        *) return 1 ;;
    esac
}

# owner_is_user FILE — true, если у развёрнутой копии во frontmatter стоит owner: user.
# Fail-open: нет читателя frontmatter или файл нечитаем → не защищаем (иначе первое
# обновление со старой версии заморозило бы вообще всю память).
owner_is_user() {
    command -v get_field >/dev/null 2>&1 || return 1
    [ -r "$1" ] || return 1
    [ "$(get_field "$1" owner 2>/dev/null)" = "user" ]
}

# Сохранение пользовательской секции при перезаписи платформенного файла (upstream 3318d72,
# 4ae0906). Маркеры USER-SPACE несут 35 файлов скиллов ветки; без этого правки пилота
# в них исчезали при каждом обновлении. sed вместо perl — тот же приём, что ниже в QWEN.md,
# лишней зависимости на Windows не добавляет.
has_user_space_slot() {
    case "$1" in
        .qwen/skills/*|.qwen/rules/*) return 0 ;;
        *) return 1 ;;
    esac
}

# === Каталоги ===
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"   # FMT-репо = источник новых файлов
WORKSPACE_DIR="$(dirname "$SCRIPT_DIR")"       # установленная среда = приёмник
ENV_FILE="$WORKSPACE_DIR/.exocortex.env"

# Читатель frontmatter для owner_is_user (upstream #229). Source мягкий: установка,
# обновляющаяся с версии до этого фикса, ещё не имеет файла на диске — он приезжает
# этим же прогоном. Без него owner_is_user отдаёт «не user», то есть прежнее поведение.
[ -f "$SCRIPT_DIR/.qwen/lib/frontmatter.sh" ] && . "$SCRIPT_DIR/.qwen/lib/frontmatter.sh"

# Guard: запуск из FMT-репо установленной среды
if [ ! -f "$SCRIPT_DIR/QWEN.md" ]; then
    echo "ОШИБКА: запускайте из корня FMT-репо (где лежит QWEN.md)." >&2
    echo "  cd ~/IWE/FMT-exocortex-template && bash update.sh" >&2
    exit 1
fi
if [ ! -f "$ENV_FILE" ]; then
    echo "ОШИБКА: $ENV_FILE не найден — среда не установлена в этом workspace." >&2
    echo "  Сначала выполните первую установку:  bash setup-offline.sh" >&2
    exit 1
fi

MANIFEST="$SCRIPT_DIR/update-manifest.json"
if [ ! -f "$MANIFEST" ]; then
    echo "ОШИБКА: $MANIFEST не найден (неполная распаковка FMT?)." >&2
    exit 1
fi
# Нативный (python.org) Windows-Python не понимает MSYS-путь git bash (/c/Work/...) —
# ему нужен c:/Work/.... Переводим один раз для обоих Python-вызовов ниже
# (manifest_paths/manifest_deprecated), вместо повтора в каждом. На Linux/macOS
# реальный абсолютный путь не начинается с одной буквы перед слэшем — не совпадает,
# поведение не меняется (находка с боевой Windows-машины, WP-25, 24.08).
MANIFEST_PY="$(printf '%s' "$MANIFEST" | sed 's|^/\([a-zA-Z]\)/|\1:/|')"

# === Значения из .exocortex.env (безопасное чтение KEY=VALUE) ===
env_get() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2-; }

HOME_DIR="$(env_get HOME_DIR)";              HOME_DIR="${HOME_DIR:-$HOME}"
GOVERNANCE_REPO="$(env_get GOVERNANCE_REPO)"; GOVERNANCE_REPO="${GOVERNANCE_REPO:-DS-strategy}"
GITHUB_USER="$(env_get GITHUB_USER)";        GITHUB_USER="${GITHUB_USER:-local}"
CLAUDE_PROJECT_SLUG="$(env_get CLAUDE_PROJECT_SLUG)"
IWE_RUNTIME_PATH="$WORKSPACE_DIR/.iwe-runtime"

# === Каталог памяти Qwen (тот же метод, что setup-offline.sh / link-memory.sh) ===
# id проекта = sanitizeCwd(cwd): Windows-путь → lowercase → [^A-Za-z0-9]→'-'.
if command -v cygpath >/dev/null 2>&1; then
    QWEN_CWD="$(cygpath -w "$WORKSPACE_DIR" 2>/dev/null || echo "$WORKSPACE_DIR")"
else
    QWEN_CWD="$WORKSPACE_DIR"
fi
QWEN_PROJECT_ID="$(printf '%s' "$QWEN_CWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-zA-Z0-9]/-/g')"
QWEN_BASE_DIR="${QWEN_HOME:-${QWEN_RUNTIME_DIR:-$HOME/.qwen}}"
QWEN_MEMORY_DIR="$QWEN_BASE_DIR/projects/$QWEN_PROJECT_ID/memory"

# === Маркер незавершённого обновления (upstream 30efdb5, v0.38.2) ===
# В $WORKSPACE_DIR, не в $SCRIPT_DIR: папка FMT-репо при офлайн-обновлении заменяется
# целиком следующей распаковкой ZIP, маркер там не пережил бы прогон, который должен
# его увидеть. Без этого обрыв прогона (сеть/Ctrl-C/ошибка на середине) не оставлял
# следа — пилот не узнавал, что часть файлов обновилась, а часть нет.
UPDATE_INCOMPLETE_MARKER="$WORKSPACE_DIR/.update-incomplete"
UPDATE_TRANSACTION_STARTED=false

begin_update_transaction() {
    if [ ! -f "$UPDATE_INCOMPLETE_MARKER" ]; then
        {
            echo "started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            echo "local_version=$VERSION"
            echo "state=applying"
        } > "$UPDATE_INCOMPLETE_MARKER"
    fi
    UPDATE_TRANSACTION_STARTED=true
}

finish_update_transaction() {
    if [ -f "$UPDATE_INCOMPLETE_MARKER" ]; then
        rm -f "$UPDATE_INCOMPLETE_MARKER"
        echo "  ✓ Маркер незавершённого обновления снят."
    fi
    UPDATE_TRANSACTION_STARTED=false
}

# run_build_runtime_or_die (upstream WP-529 F6, issue найден на реальном обновлении
# пилота): раньше сбой build-runtime.sh проглатывался целиком — статус проверялся у
# `sed` из конвейера `... | sed ... || echo warning`, не у самого build-runtime.sh, так
# что предупреждение практически никогда не срабатывало. Маркер незавершённого
# обновления при этом снимался как обычно — сборка окружения могла остаться битой, а
# прогон отчитывался как успешный. Теперь: сбой = маркер остаётся, обновление
# считается незавершённым, повторный запуск после починки причины сходится сам.
run_build_runtime_or_die() {
    [ -f "$SCRIPT_DIR/setup/build-runtime.sh" ] || return 0
    echo ""
    echo "Generated runtime (.iwe-runtime/)..."
    local brt_out brt_status
    if brt_out=$(bash "$SCRIPT_DIR/setup/build-runtime.sh" \
        --workspace "$WORKSPACE_DIR" --env-file "$ENV_FILE" --quiet 2>&1); then
        brt_status=0
    else
        brt_status=$?
    fi
    [ -n "$brt_out" ] && printf '%s\n' "$brt_out" | sed 's/^/  /'
    if [ "$brt_status" -ne 0 ]; then
        echo "✗ build-runtime.sh завершился с ошибкой (код $brt_status). Обновление НЕ завершено: маркер незавершённого обновления сохранён." >&2
        echo "  Проверьте .exocortex.env (значения placeholders) и повторите: bash $SCRIPT_DIR/update.sh" >&2
        exit 1
    fi
}

echo "=========================================="
echo "  Exocortex Update — offline v$VERSION"
echo "=========================================="
echo "  FMT (источник):  $SCRIPT_DIR"
echo "  Workspace:       $WORKSPACE_DIR"
echo "  Каталог памяти:  $QWEN_MEMORY_DIR"
echo ""
if [ -f "$UPDATE_INCOMPLETE_MARKER" ]; then
    echo "⚠ Найден маркер незавершённого обновления: $UPDATE_INCOMPLETE_MARKER"
    echo "  Предыдущий запуск мог применить только часть файлов; успешный повторный запуск снимет маркер."
    echo ""
fi

# === Temp ===
TMPDIR_UPDATE="$(mktemp -d 2>/dev/null || { mkdir -p "/tmp/exo-update-$$"; echo "/tmp/exo-update-$$"; })"

# cleanup_update — заменяет голый `trap rm -rf ... EXIT`. Если прогон транзакции
# начался (begin_update_transaction), но скрипт вышел с ошибкой — маркер остаётся
# нарочно (upstream 30efdb5): следующий запуск должен его увидеть.
cleanup_update() {
    local status=$?
    rm -rf "$TMPDIR_UPDATE"
    if [ "$UPDATE_TRANSACTION_STARTED" = true ] && [ "$status" -ne 0 ] && [ -f "$UPDATE_INCOMPLETE_MARKER" ]; then
        echo "⚠ Обновление завершилось не полностью; маркер сохранён: $UPDATE_INCOMPLETE_MARKER" >&2
        echo "  Применено файлов шаблона: ${APPLIED:-0} из ${TOTAL_CHANGES:-неизвестно}; рабочие копии могли обновиться частично." >&2
        echo "  Исправьте причину и перезапустите update.sh." >&2
    fi
    return "$status"
}
trap cleanup_update EXIT

# === Подстановка плейсхолдеров (как setup-offline.sh) ===
substitute_placeholders() {
    sed_inplace \
        -e "s|{{HOME_DIR}}|$HOME_DIR|g" \
        -e "s|{{WORKSPACE_DIR}}|$WORKSPACE_DIR|g" \
        -e "s|{{GOVERNANCE_REPO}}|$GOVERNANCE_REPO|g" \
        -e "s|{{STRATEGY_REPO}}|$GOVERNANCE_REPO|g" \
        -e "s|{{GITHUB_USER}}|$GITHUB_USER|g" \
        -e "s|{{CLAUDE_PROJECT_SLUG}}|$CLAUDE_PROJECT_SLUG|g" \
        -e "s|{{IWE_TEMPLATE}}|$SCRIPT_DIR|g" \
        -e "s|{{IWE_RUNTIME}}|$IWE_RUNTIME_PATH|g" \
        "$1"
}

# target в установленной среде для файла из манифеста (пусто = вне scope обновления)
target_path() {
    case "$1" in
        QWEN.md) echo "$WORKSPACE_DIR/QWEN.md" ;;
        # Путь относительно memory/, не basename (upstream #287/#294): basename ронял
        # memory/reference/agent-core.md в плоский memory/agent-core.md, и ссылки на него
        # из QWEN.md указывали в никуда.
        memory/*.md|memory/*.yaml|memory/*.yml) echo "$QWEN_MEMORY_DIR/${1#memory/}" ;;
        # rules-lazy/styles/templates добавлены вслед за шаблоном (upstream 489db97, 3c3365e,
        # 8c94681): без них 10 файлов манифеста получали пустой адрес и молча выпадали
        # из обновления — ни в одном списке отчёта они не появлялись.
        .qwen/skills/*|.qwen/hooks/*|.qwen/rules/*|.qwen/rules-lazy/*|.qwen/lib/*|.qwen/config/*|.qwen/detectors/*|.qwen/scripts/*|.qwen/agents/*|.qwen/styles/*|.qwen/templates/*|.qwen/settings.json|.qwen/settings.local.json)
            echo "$WORKSPACE_DIR/$1" ;;
        *) echo "" ;;
    esac
}

# === Чтение списка файлов манифеста ===
# Вывод буферизуется, а не льётся сразу в потребителя: прежняя форма
# `python3 -c "..." || grep-запасной` при обрыве интерпретатора на середине отдавала
# частичный список И следом запасной — потребитель читал дубли. Заглушка Microsoft
# Store вдобавок печатает свой отказ в stdout (не в stderr), то есть её текст попадал
# в тот же поток. Сначала собираем, потом решаем, чей результат отдать.
#
# Код возврата берётся из самого интерпретатора, БЕЗ конвейера: `$(cmd | tr -d '\r')`
# отдал бы статус `tr` (всегда 0), и сбой Python стал бы неотличим от пустого списка —
# ровно тот тихий отказ, который здесь и чинится. Возврат каретки снимаем подстановкой
# самого bash. Нативный Windows Python эмитит CRLF даже в пайп, читаемый git bash, и
# `\r` уезжает в ПОСЛЕДНЕЕ поле строки (upstream #402, дефект 3); у нас это описание
# файла (не используется) и причина устаревания (только печать) — ущерб косметический,
# но снятие бесплатно и защищает от новых полей.
manifest_paths() {
    local out="" rc=0
    if py_available; then
        # shellcheck disable=SC2086  # PY_BIN может быть "py -3" — см. комментарий у объявления.
        out=$($PY_BIN -c "
import json
with open('$MANIFEST_PY', encoding='utf-8') as f:
    data = json.load(f)
for e in data.get('files', []):
    print(e['path'] + '|' + e.get('desc',''))
" 2>/dev/null) || rc=$?
        if [ "$rc" -eq 0 ]; then
            out="${out//$'\r'/}"
            [ -n "$out" ] && printf '%s\n' "$out"
            return 0
        fi
    fi
    warn_py_degraded
    grep '"path"' "$MANIFEST" | sed 's/.*"path"[[:space:]]*:[[:space:]]*"//;s/".*/|/'
}
manifest_deprecated() {
    local out="" rc=0
    # Запасного пути нет: список снятых с поставки файлов не вытащить grep'ом (нужна
    # пара путь+причина из вложенной структуры). Поэтому при отказе Python чистка
    # устаревших файлов не выполняется — об этом и предупреждает warn_py_degraded.
    py_available || { warn_py_degraded; return 0; }
    # shellcheck disable=SC2086  # PY_BIN может быть "py -3" — см. комментарий у объявления.
    out=$($PY_BIN -c "
import json, sys
with open('$MANIFEST_PY', encoding='utf-8') as f:
    data = json.load(f)
# upstream (внешний репорт 2026-08-22): путь одновременно в поставке и в
# deprecated_files — рассинхронизация генератора манифеста, а не сигнал к удалению.
# Поставка побеждает; конфликт сообщается, но не исполняется.
delivered = {e.get('path') for e in data.get('files', [])}
for e in data.get('deprecated_files', []):
    path = e.get('path', '')
    if path in delivered:
        print('  ⚠ %s: и в поставке, и в списке устаревших — удаление пропущено (несогласованный манифест)' % path, file=sys.stderr)
        continue
    print(path + '|' + e.get('reason',''))
") || rc=$?
    if [ "$rc" -ne 0 ]; then
        warn_py_degraded
        return 0
    fi
    out="${out//$'\r'/}"
    [ -n "$out" ] && printf '%s\n' "$out"
    return 0
}

# === Step 1: детект изменений ===
echo "[1] Сравнение файлов..."
NEW_FILES=()
UPDATED_FILES=()
UNCHANGED=0
OWNER_USER_DRIFT=()   # owner: user — не обновляем, но о расхождении сообщаем (upstream #375)

while IFS='|' read -r fpath fdesc; do
    [ -z "$fpath" ] && continue
    tgt="$(target_path "$fpath")"
    [ -z "$tgt" ] && continue                    # вне scope обновления (FMT read-only / build-runtime)
    src="$SCRIPT_DIR/$fpath"
    [ -f "$src" ] || continue
    bn="$(basename "$fpath")"

    # Protected: пропускаем если уже существуют
    if [ "$bn" = "MEMORY.md" ] && [ -f "$tgt" ]; then UNCHANGED=$((UNCHANGED+1)); continue; fi
    if [ "$fpath" = ".qwen/settings.local.json" ] && [ -f "$tgt" ]; then UNCHANGED=$((UNCHANGED+1)); continue; fi
    if is_personal_config "$bn" && [ -f "$tgt" ]; then UNCHANGED=$((UNCHANGED+1)); continue; fi

    # owner: user во frontmatter развёрнутой копии — файл принадлежит пилоту, не трогаем
    # (upstream #229). Защита не должна делать расхождение с шаблоном невидимым, поэтому
    # отличие копируем не в файл, а в отчёт (upstream #375). Список исключений — выше (#354/#384):
    # старые релизы поставляли эти файлы с owner: user, и legacy-маркер иначе заморозил бы их навсегда.
    if [ -f "$tgt" ] && ! is_migrated_platform_memory_path "$fpath" && owner_is_user "$tgt"; then
        [ "$(hash_file "$src")" != "$(hash_file "$tgt")" ] && OWNER_USER_DRIFT+=("$fpath")
        UNCHANGED=$((UNCHANGED+1))
        continue
    fi

    # QWEN.md сравниваем с подставленной версией
    if [ "$fpath" = "QWEN.md" ]; then
        cmp_src="$TMPDIR_UPDATE/QWEN.md.subst"
        cp "$src" "$cmp_src"; substitute_placeholders "$cmp_src"
        src="$cmp_src"
        # Файл под трёхсторонним слиянием законно расходится с шаблоном правками пилота,
        # поэтому сравнение исходник↔цель показывало бы «изменён» каждый прогон и вхолостую
        # гоняло merge. Сравниваем база↔исходник: двигался ли сам шаблон (upstream #254).
        qwen_base="$WORKSPACE_DIR/.qwen.md.base"
        if [ -f "$qwen_base" ] && [ -f "$tgt" ]; then
            if [ "$(hash_file "$src")" = "$(hash_file "$qwen_base")" ]; then
                UNCHANGED=$((UNCHANGED+1)); continue
            fi
            UPDATED_FILES+=("$fpath"); continue
        fi
    fi

    if [ ! -f "$tgt" ]; then
        NEW_FILES+=("$fpath")
    elif [ "$(hash_file "$src")" != "$(hash_file "$tgt")" ]; then
        UPDATED_FILES+=("$fpath")
    else
        UNCHANGED=$((UNCHANGED+1))
    fi
done < <(manifest_paths)

DEPRECATED_FOUND=()
DEPRECATED_REASONS=()
while IFS='|' read -r fpath freason; do
    [ -z "$fpath" ] && continue
    tgt="$(target_path "$fpath")"
    [ -n "$tgt" ] && [ -f "$tgt" ] && { DEPRECATED_FOUND+=("$fpath"); DEPRECATED_REASONS+=("${freason:-устарел}"); }
done < <(manifest_deprecated)

TOTAL_CHANGES=$(( ${#NEW_FILES[@]} + ${#UPDATED_FILES[@]} + ${#DEPRECATED_FOUND[@]} ))

# === Step 2: показать ===
echo ""
echo "=========================================="
echo "  Обновления среды"
echo "=========================================="
echo ""
# Защита owner: user не должна делать расхождение с шаблоном невидимым (upstream #375):
# файл не обновляем, но о том, что шаблонная версия ушла вперёд, сообщаем всегда —
# в том числе когда обновлять больше нечего.
if [ ${#OWNER_USER_DRIFT[@]} -gt 0 ]; then
    echo "Ваши файлы (owner: user) — НЕ обновляются, но шаблонная версия отличается (${#OWNER_USER_DRIFT[@]}):"
    for f in "${OWNER_USER_DRIFT[@]}"; do
        echo "  ⚠ $f — сверьте: diff \"$SCRIPT_DIR/$f\" \"$(target_path "$f")\""
    done
    echo ""
fi
if [ "$TOTAL_CHANGES" -eq 0 ]; then
    echo "✓ Всё актуально. Обновлений нет. ($UNCHANGED файлов проверено)"
    finish_update_transaction
    exit 0
fi
if [ ${#NEW_FILES[@]} -gt 0 ]; then
    echo "Новые файлы (${#NEW_FILES[@]}):"
    for f in "${NEW_FILES[@]}"; do echo "  + $f"; done
    echo ""
fi
if [ ${#UPDATED_FILES[@]} -gt 0 ]; then
    echo "Обновлённые файлы (${#UPDATED_FILES[@]}):"
    for f in "${UPDATED_FILES[@]}"; do
        [ "$f" = "QWEN.md" ] && echo "  ~ $f (3-way merge, ваши правки сохраняются)" || echo "  ~ $f"
    done
    echo ""
fi
if [ ${#DEPRECATED_FOUND[@]} -gt 0 ]; then
    echo "Устаревшие файлы к удалению (${#DEPRECATED_FOUND[@]}):"
    for i in "${!DEPRECATED_FOUND[@]}"; do
        printf "  - %-45s — %s\n" "${DEPRECATED_FOUND[$i]}" "${DEPRECATED_REASONS[$i]}"
    done
    echo ""
fi
echo "Не затрагиваются:"
echo "  ✓ memory/MEMORY.md (оперативная память)"
echo "  ✓ memory/day-rhythm-config.yaml (личный ритм)"
echo "  ✓ params.yaml, .qwen/settings.local.json"
echo "  ✓ DS-strategy/, extensions/ (ваши данные и расширения)"
echo ""
[ "$UNCHANGED" -gt 0 ] && { echo "Без изменений: $UNCHANGED файлов"; echo ""; }

if $CHECK_ONLY; then
    echo "Режим --check: изменения не применяются."
    echo "Для применения: bash update.sh"
    exit 0
fi
if ! $AUTO_YES; then
    read -rp "Применить обновления? (y/n) " ans
    case "$ans" in y|Y) ;; *) echo "Отменено."; exit 0 ;; esac
fi

# === Step 3: бэкап памяти ===
if [ -d "$QWEN_MEMORY_DIR" ] && [ -n "$(ls -A "$QWEN_MEMORY_DIR" 2>/dev/null)" ]; then
    MEM_BAK="$QWEN_MEMORY_DIR.bak-$(date +%Y%m%d-%H%M%S)"
    cp -r "$QWEN_MEMORY_DIR" "$MEM_BAK"
    echo ""
    echo "Бэкап памяти: $MEM_BAK"
fi

# === Step 4: применение ===
echo ""
echo "Применяю обновления..."
begin_update_transaction
APPLIED=0
REMOVED=0
QWEN_BASE_MISSING=false   # QWEN.md не тронут: слить не с чем, а слепо перезаписывать нельзя
RULES_BACKUP_DIR=""       # каталог бэкапа правил этого прогона, создаётся при первой перезаписи
RULES_SAFE_TO_UPDATE="|"  # снимок «какие правила совпадали с последним применённым эталоном»

# === Снимок-эталон для .qwen/rules/* (адаптация upstream 30efdb5, v0.38.2) ===
# Апстрим сравнивает деплой с СОБСТВЕННОЙ старой копией шаблона (SCRIPT_DIR до того, как
# сетевой шаг перезаписал её новым содержимым) — так отличает «правило сменилось само
# по себе» от «пилот правил его руками». В офлайне это не работает: папка FMT-репо
# (SCRIPT_DIR) заменяется целиком ДО запуска скрипта, старой версии внутри просто нет —
# буквальный порт сравнивал бы новый шаблон с деплоем и принимал ЛЮБОЕ шаблонное
# изменение за ручную правку пилота, блокируя обычные обновления (найдено проверкой 10.08).
#
# Решение: держим свой эталон — скрытую копию каждого развёрнутого правила, обновляемую
# после каждого успешного применения. Сравниваем деплой с ЭТИМ эталоном, не с новым
# шаблоном. Совпадает → с последнего обновления никто руками не лез → безопасно
# перезаписывать. Эталона ещё нет (первый прогон после этой правки) → безопасно, эталон
# заведётся этим же прогоном — единственная цена бутстрапа: самая первая перезапись после
# обновления скрипта не защищена, как и в апстриме на пустой истории.
RULES_BASELINE_DIR="$WORKSPACE_DIR/.qwen-rules.baseline"

rule_baseline_path() {
    printf '%s/%s' "$RULES_BASELINE_DIR" "${1#.qwen/rules/}"
}

record_rule_workspace_state() {
    local fpath="$1" dst baseline
    case "$fpath" in .qwen/rules/*) ;; *) return 0 ;; esac
    dst="$(target_path "$fpath")"
    baseline="$(rule_baseline_path "$fpath")"
    if [ ! -f "$dst" ] || [ ! -f "$baseline" ] || [ "$(hash_file "$dst")" = "$(hash_file "$baseline")" ]; then
        RULES_SAFE_TO_UPDATE="${RULES_SAFE_TO_UPDATE}${fpath}|"
    fi
}

rule_was_safe_to_update() {
    case "$RULES_SAFE_TO_UPDATE" in *"|$1|"*) return 0 ;; *) return 1 ;; esac
}

# Обновить эталон текущим (уже применённым) содержимым — вызывается после каждого
# успешного копирования правила, чтобы следующий прогон сравнивал с актуальной версией.
save_rule_baseline() {
    local fpath="$1" dst="$2" baseline
    case "$fpath" in .qwen/rules/*) ;; *) return 0 ;; esac
    baseline="$(rule_baseline_path "$fpath")"
    mkdir -p "$(dirname "$baseline")"
    cp "$dst" "$baseline"
}

# Бэкап правила перед перезаписью (upstream 4ae0906): в .qwen/rules/ живут файлы,
# которые пилот правит чаще всего, а USER-SPACE есть не в каждом из них.
backup_rule_before_overwrite() {
    local fpath="$1" dst="$2" backup
    case "$fpath" in .qwen/rules/*) ;; *) return 0 ;; esac
    [ -f "$dst" ] || return 0
    [ -z "$RULES_BACKUP_DIR" ] && RULES_BACKUP_DIR="$WORKSPACE_DIR/.backups/rules-pre-update/$(date +%Y%m%d-%H%M%S)-$$"
    backup="$RULES_BACKUP_DIR/${fpath#.qwen/rules/}"
    mkdir -p "$(dirname "$backup")"
    cp "$dst" "$backup"
    # Построчно не отчитываемся: каталог бэкапа называется один раз в итоге прогона.
}

# Копирование платформенного файла с сохранением пользовательской секции (upstream 3318d72).
# Суффикс для строки отчёта отдаётся через USER_SPACE_NOTE, а не через stdout: внутри
# пишет в лог backup_rule_before_overwrite, и общий поток склеил бы лог с возвращаемым
# значением в одну строку.
USER_SPACE_NOTE=""
copy_preserving_user_space() {
    local src="$1" dst="$2" fpath="$3" usr=""
    USER_SPACE_NOTE=""
    if [ -f "$dst" ] && has_user_space_slot "$fpath"; then
        # Guard дивергенции (upstream 30efdb5, адаптация — см. комментарий у
        # record_rule_workspace_state) — только для .qwen/rules/*, скиллы им не
        # покрываются (апстрим вводит его тоже только для .claude/rules/*). Снимок уже
        # решил «безопасно ли» до начала обновления; здесь — только применение решения.
        case "$fpath" in
            .qwen/rules/*)
                if ! rule_was_safe_to_update "$fpath"; then
                    backup_rule_before_overwrite "$fpath" "$dst"
                    USER_SPACE_NOTE=" — НЕ обновлён, рабочая копия отличается от последнего применённого эталона (сверьте: diff \"$src\" \"$dst\")"
                    return 1
                fi
                ;;
        esac
        backup_rule_before_overwrite "$fpath" "$dst"
        usr="$(sed -n '/^<!-- USER-SPACE/,/^<!-- \/USER-SPACE/p' "$dst")"
    fi
    cp "$src" "$dst"
    if [ -n "$usr" ]; then
        sed_inplace '/^<!-- USER-SPACE/,/^<!-- \/USER-SPACE/d' "$dst"
        printf '\n%s\n' "$usr" >> "$dst"
        USER_SPACE_NOTE=" (USER-SPACE сохранён)"
    fi
    save_rule_baseline "$fpath" "$dst"
}

apply_file() {
    local fpath="$1"
    local tgt; tgt="$(target_path "$fpath")"
    local src="$SCRIPT_DIR/$fpath"
    local bn; bn="$(basename "$fpath")"

    if [ "$fpath" = "QWEN.md" ]; then
        local new="$TMPDIR_UPDATE/QWEN.md.new"
        cp "$src" "$new"; substitute_placeholders "$new"
        local base="$WORKSPACE_DIR/.qwen.md.base"
        if [ -f "$base" ] && [ -f "$tgt" ] && command -v git >/dev/null 2>&1; then
            local merged="$TMPDIR_UPDATE/QWEN.md.merged"
            cp "$tgt" "$merged"
            if git merge-file -p "$merged" "$base" "$new" > "$TMPDIR_UPDATE/QWEN.md.out" 2>/dev/null; then
                cp "$TMPDIR_UPDATE/QWEN.md.out" "$tgt"; cp "$new" "$base"
                echo "  ~ QWEN.md (3-way merge, чисто)"
            else
                local cc; cc=$(grep -c '^<<<<<<<' "$TMPDIR_UPDATE/QWEN.md.out" 2>/dev/null || echo 0)
                cp "$TMPDIR_UPDATE/QWEN.md.out" "$tgt"; cp "$new" "$base"
                if [ "$cc" -gt 0 ]; then
                    echo "  ~ QWEN.md (3-way merge, $cc конфликтов — разрешите вручную: <<<<<<< / ======= / >>>>>>>)"
                else
                    echo "  ~ QWEN.md (3-way merge)"
                fi
            fi
        elif [ ! -f "$tgt" ]; then
            # Первая установка: терять нечего.
            cp "$new" "$tgt"; cp "$new" "$base"
            echo "  ~ QWEN.md (создан)"
        else
            # Базового файла для слияния нет. Если пилот обозначил свою секцию маркерами —
            # переносим её и создаём базу. Если маркеров нет, слепой cp стирал бы правки
            # в §8/§9 (они маркерами не обёрнуты) — файл не трогаем и предупреждаем,
            # как это делает шаблон (upstream #336).
            local usr; usr="$(sed -n '/^<!-- USER-SPACE/,/^<!-- \/USER-SPACE/p' "$tgt")"
            if [ -n "$usr" ]; then
                cp "$new" "$tgt"
                sed_inplace '/^<!-- USER-SPACE/,/^<!-- \/USER-SPACE/d' "$tgt"
                printf '\n%s\n' "$usr" >> "$tgt"
                cp "$new" "$base"
                echo "  ~ QWEN.md (USER-SPACE сохранён, базовый файл создан)"
            else
                cp "$new" "$base"
                QWEN_BASE_MISSING=true
                echo "  ⚠ QWEN.md НЕ тронут — базового файла для слияния не было."
                echo "    Сверьте свои правки §8/§9 вручную: diff \"$tgt\" \"$base\""
                return 0
            fi
        fi
    else
        mkdir -p "$(dirname "$tgt")"
        if ! copy_preserving_user_space "$src" "$tgt" "$fpath"; then
            echo "  ⚠ $fpath$USER_SPACE_NOTE"
            return 0
        fi
        case "$fpath" in *.sh) chmod +x "$tgt" ;; esac
        echo "  ~ $fpath$USER_SPACE_NOTE"
    fi
    APPLIED=$((APPLIED+1))
}

# Снимок дивергенции — ДО первого apply_file, иначе после первого копирования
# рабочая копия уже равна новому шаблону и снимок не отличит «пилот правил» от
# «мы только что записали» (upstream 30efdb5).
for f in "${NEW_FILES[@]}" "${UPDATED_FILES[@]}"; do record_rule_workspace_state "$f"; done

for f in "${NEW_FILES[@]}";     do apply_file "$f"; done
for f in "${UPDATED_FILES[@]}"; do apply_file "$f"; done

# deprecated cleanup
for i in "${!DEPRECATED_FOUND[@]}"; do
    f="${DEPRECATED_FOUND[$i]}"; tgt="$(target_path "$f")"
    [ -n "$tgt" ] && [ -f "$tgt" ] && rm -f "$tgt" && echo "  - $f (удалён: устарел)" && REMOVED=$((REMOVED+1))
done

# repair-pass (lite): scope-файлы, отсутствующие в target, — досоздать
while IFS='|' read -r fpath _; do
    [ -z "$fpath" ] && continue
    tgt="$(target_path "$fpath")"; [ -z "$tgt" ] && continue
    src="$SCRIPT_DIR/$fpath"; [ -f "$src" ] || continue
    bn="$(basename "$fpath")"
    [ "$bn" = "MEMORY.md" ] && continue
    [ "$fpath" = "QWEN.md" ] && continue
    if [ ! -f "$tgt" ]; then
        mkdir -p "$(dirname "$tgt")"; cp "$src" "$tgt"
        case "$fpath" in *.sh) chmod +x "$tgt" ;; esac
        echo "  ⟲ $fpath (восстановлен)"; APPLIED=$((APPLIED+1))
    fi
done < <(manifest_paths)

# === Step 5: generated runtime (.iwe-runtime/, params.yaml, .qwen/sync-manifest.yaml) ===
run_build_runtime_or_die

# === Step 6: ~/.iwe-paths (lookup-слой путей, ~/.bashrc; идемпотентно) ===
if [ -f "$SCRIPT_DIR/setup/install-iwe-paths.sh" ]; then
    bash "$SCRIPT_DIR/setup/install-iwe-paths.sh" \
        --workspace "$WORKSPACE_DIR" --governance "$GOVERNANCE_REPO" --template "$SCRIPT_DIR" --quiet 2>&1 | sed 's/^/  /' || true
fi

# === Готово ===
echo ""
echo "=========================================="
SUMMARY="  Обновление завершено ($APPLIED файлов"
[ "$REMOVED" -gt 0 ] && SUMMARY="$SUMMARY, $REMOVED удалено"
SUMMARY="$SUMMARY)"
echo "$SUMMARY"
echo "=========================================="
echo ""
if $QWEN_BASE_MISSING; then
    echo "⚠ QWEN.md остался вашей версией — базового файла для слияния не было."
    echo "  Сверьте §8/§9 с шаблонной версией (команда diff показана выше) и внесите правки вручную."
    echo "  Базовый файл создан, следующее обновление пройдёт обычным трёхсторонним слиянием."
    echo ""
fi
[ -n "$RULES_BACKUP_DIR" ] && { echo "Прежние версии правил: $RULES_BACKUP_DIR"; echo ""; }
echo "Перезапустите qwen для применения обновлений в памяти и .qwen/."
finish_update_transaction
