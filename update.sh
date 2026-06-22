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

# === Личные L4-конфиги в памяти: сеять при отсутствии, НИКОГДА не перезаписывать ===
# (персональные правки — calendar_ids, slot-настройки). MEMORY.md защищён отдельно.
is_personal_config() {
    case "$1" in
        day-rhythm-config.yaml) return 0 ;;
        *) return 1 ;;
    esac
}

# === Каталоги ===
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"   # FMT-репо = источник новых файлов
WORKSPACE_DIR="$(dirname "$SCRIPT_DIR")"       # установленная среда = приёмник
ENV_FILE="$WORKSPACE_DIR/.exocortex.env"

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

echo "=========================================="
echo "  Exocortex Update — offline v$VERSION"
echo "=========================================="
echo "  FMT (источник):  $SCRIPT_DIR"
echo "  Workspace:       $WORKSPACE_DIR"
echo "  Каталог памяти:  $QWEN_MEMORY_DIR"
echo ""

# === Temp ===
TMPDIR_UPDATE="$(mktemp -d 2>/dev/null || { mkdir -p "/tmp/exo-update-$$"; echo "/tmp/exo-update-$$"; })"
trap 'rm -rf "$TMPDIR_UPDATE"' EXIT

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
        memory/*.md|memory/*.yaml|memory/*.yml) echo "$QWEN_MEMORY_DIR/$(basename "$1")" ;;
        .qwen/skills/*|.qwen/hooks/*|.qwen/rules/*|.qwen/lib/*|.qwen/config/*|.qwen/detectors/*|.qwen/scripts/*|.qwen/agents/*|.qwen/settings.json|.qwen/settings.local.json)
            echo "$WORKSPACE_DIR/$1" ;;
        *) echo "" ;;
    esac
}

# === Чтение списка файлов манифеста ===
manifest_paths() {
    python3 -c "
import json
with open('$MANIFEST') as f:
    data = json.load(f)
for e in data.get('files', []):
    print(e['path'] + '|' + e.get('desc',''))
" 2>/dev/null || grep '"path"' "$MANIFEST" | sed 's/.*"path"[[:space:]]*:[[:space:]]*"//;s/".*/|/'
}
manifest_deprecated() {
    python3 -c "
import json
with open('$MANIFEST') as f:
    data = json.load(f)
for e in data.get('deprecated_files', []):
    print(e.get('path','') + '|' + e.get('reason',''))
" 2>/dev/null || true
}

# === Step 1: детект изменений ===
echo "[1] Сравнение файлов..."
NEW_FILES=()
UPDATED_FILES=()
UNCHANGED=0

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

    # QWEN.md сравниваем с подставленной версией
    if [ "$fpath" = "QWEN.md" ]; then
        cmp_src="$TMPDIR_UPDATE/QWEN.md.subst"
        cp "$src" "$cmp_src"; substitute_placeholders "$cmp_src"
        src="$cmp_src"
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
if [ "$TOTAL_CHANGES" -eq 0 ]; then
    echo "✓ Всё актуально. Обновлений нет. ($UNCHANGED файлов проверено)"
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
APPLIED=0
REMOVED=0

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
        else
            # fallback: сохранить USER-SPACE секцию
            local usr=""
            [ -f "$tgt" ] && usr="$(sed -n '/^<!-- USER-SPACE/,/^<!-- \/USER-SPACE/p' "$tgt")"
            cp "$new" "$tgt"
            if [ -n "$usr" ]; then
                sed_inplace '/^<!-- USER-SPACE/,/^<!-- \/USER-SPACE/d' "$tgt"
                printf '\n%s\n' "$usr" >> "$tgt"
                echo "  ~ QWEN.md (USER-SPACE сохранён, базовый файл создан)"
            else
                echo "  ~ QWEN.md (базовый файл создан)"
            fi
            cp "$new" "$base"
        fi
    else
        mkdir -p "$(dirname "$tgt")"
        cp "$src" "$tgt"
        case "$fpath" in *.sh) chmod +x "$tgt" ;; esac
        echo "  ~ $fpath"
    fi
    APPLIED=$((APPLIED+1))
}

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
if [ -f "$SCRIPT_DIR/setup/build-runtime.sh" ]; then
    echo ""
    echo "Generated runtime (.iwe-runtime/)..."
    bash "$SCRIPT_DIR/setup/build-runtime.sh" \
        --workspace "$WORKSPACE_DIR" --env-file "$ENV_FILE" --quiet 2>&1 | sed 's/^/  /' || \
        echo "  ⚠ build-runtime.sh завершился с ошибкой. Запустите вручную: bash $SCRIPT_DIR/setup/build-runtime.sh --workspace \"$WORKSPACE_DIR\" --env-file \"$ENV_FILE\""
fi

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
echo "Перезапустите qwen для применения обновлений в памяти и .qwen/."
