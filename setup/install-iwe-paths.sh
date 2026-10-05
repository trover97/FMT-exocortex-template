#!/bin/bash
# install-iwe-paths.sh — генерация $HOME/.iwe-paths + sourcing из ~/.zshenv.
#
# Source-of-truth для IWE_* path-переменных (WP-219, DP.FM.009).
# Вызывается из:
#   - setup.sh (первичная установка)
#   - scripts/migrate-to-runtime-target.sh (миграция 0.28.x → 0.29.x)
#   - update.sh (повторная генерация после апгрейда — на случай если шаблон строки меняется)
#
# OwnerIntegrity: один файл — одно место. Раньше блок был дублирован в setup.sh [4d];
# при миграции ~/.iwe-paths не апгрейдился (Round 5 Евгения, 27 апр).
#
# Usage:
#   bash install-iwe-paths.sh --workspace PATH --governance REPO_NAME [--dry-run] [--quiet]
#
# Env:
#   IWE_ALLOW_FOREIGN_WORKSPACE=1 — overwrite ~/.iwe-paths even if it points at another
#                                   workspace (deliberate move of the primary install)
#
# Exit codes:
#   0 — успех
#   1 — некорректные аргументы

set -eu

WORKSPACE_DIR=""
GOVERNANCE_REPO=""
TEMPLATE_DIR=""        # явный путь к FMT-репо (любое имя/расположение)
DRY_RUN=false
QUIET=false

while [ $# -gt 0 ]; do
    case "$1" in
        --workspace)  WORKSPACE_DIR="$2"; shift 2 ;;
        --governance) GOVERNANCE_REPO="$2"; shift 2 ;;
        --template)   TEMPLATE_DIR="$2"; shift 2 ;;
        --dry-run)    DRY_RUN=true; shift ;;
        --quiet|-q)   QUIET=true; shift ;;
        --help|-h)
            grep '^#' "$0" | head -20
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [ -z "$WORKSPACE_DIR" ]; then
    echo "ERROR: --workspace обязателен" >&2
    exit 1
fi

WORKSPACE_DIR="${WORKSPACE_DIR/#\~/$HOME}"
GOVERNANCE_REPO="${GOVERNANCE_REPO:-DS-strategy}"
TEMPLATE_DIR="${TEMPLATE_DIR/#\~/$HOME}"
# Default (обратная совместимость): FMT внутри workspace под каноничным именем.
TEMPLATE_DIR="${TEMPLATE_DIR:-$WORKSPACE_DIR/FMT-exocortex-template}"

IWE_ENV_FILE="$HOME/.iwe-paths"
# Offline/Windows ветка: оболочка — git bash, не zsh. Источник переменных —
# ~/.bashrc. Если есть и ~/.zshenv (двойная среда) — прописываем в оба.
RC_FILES=("$HOME/.bashrc")
[ -f "$HOME/.zshenv" ] && RC_FILES+=("$HOME/.zshenv")
IWE_ENV_MARKER="# IWE environment (WP-219, DP.FM.009): lookup-слой для путей к скриптам"

# Port of upstream issue #768 (main aa870ed, update.sh detect_host_global_owner_conflict).
# In this branch the host-global resource is ~/.iwe-paths itself: it carries the
# workspace path, and the rc files only source it. Rerunning setup-offline.sh or
# update.sh from a second copy of the workspace (a test unpack of a new ZIP next to
# the working one) silently retargeted every shell and agent onto that copy. Upstream
# checks this in update.sh only; here the check sits next to the write, so both
# callers are covered. A virgin machine (no file, or no IWE_WORKSPACE line) still
# lets the first run claim ownership.
canonical_workspace_path() {
    if [ -d "$1" ]; then
        (cd "$1" 2>/dev/null && pwd -P)
    else
        printf '%s\n' "${1%/}"
    fi
}

HOST_OWNER_CONFLICT=""
if [ "${IWE_ALLOW_FOREIGN_WORKSPACE:-0}" != "1" ] && [ -f "$IWE_ENV_FILE" ]; then
    EXISTING_WS=$(sed -n 's/^export IWE_WORKSPACE="\(.*\)"$/\1/p' "$IWE_ENV_FILE" | head -1)
    if [ -n "$EXISTING_WS" ] && \
       [ "$(canonical_workspace_path "$EXISTING_WS")" != "$(canonical_workspace_path "$WORKSPACE_DIR")" ]; then
        HOST_OWNER_CONFLICT="$IWE_ENV_FILE points to $EXISTING_WS"
    fi
fi

if [ -n "$HOST_OWNER_CONFLICT" ]; then
    # Not quiet-gated: the caller runs with --quiet, and a silent skip is exactly the
    # "nothing happened, nothing said" failure this check exists to prevent.
    echo "  ⚠ $HOST_OWNER_CONFLICT — ~/.iwe-paths и ${RC_FILES[*]} НЕ изменены."
    echo "    Если это осознанный перенос основной установки: IWE_ALLOW_FOREIGN_WORKSPACE=1"
elif $DRY_RUN; then
    $QUIET || echo "  [DRY RUN] Would write $IWE_ENV_FILE (workspace=$WORKSPACE_DIR, governance=$GOVERNANCE_REPO)"
    $QUIET || echo "  [DRY RUN] Would ensure ${RC_FILES[*]} source \$HOME/.iwe-paths"
fi
$DRY_RUN && exit 0

# Port of upstream issue #957 (main 27d79bdb): a live scripts/ checkout at workspace
# root wins over the template copy, and "live" means a REGULAR (non-symlink)
# session-guard.sh there. Same rule and marker as .qwen/lib/iwe-env-bootstrap.sh.
# An offline install normally has no such checkout, so the value stays the template's.
SCRIPTS_MARKER="$WORKSPACE_DIR/scripts/session-guard.sh"
if [ -f "$SCRIPTS_MARKER" ] && [ ! -L "$SCRIPTS_MARKER" ]; then
    IWE_SCRIPTS_TARGET="\$IWE_WORKSPACE/scripts"
else
    IWE_SCRIPTS_TARGET="\$IWE_TEMPLATE/scripts"
fi

# Port of upstream issue #966 (main 27d79bdb): session-guard.sh treats an EXPLICIT
# IWE_SESSIONS_ROOT as deliberate and refuses without fallback when it is missing.
# setup-offline.sh never creates MC-sessions, so the unconditional value written by
# cycle 11 broke `session-guard.sh open` on every offline install. Name it only while
# it exists; otherwise write an empty value (the resolver treats empty as unset and
# keeps its legacy fallback). The file keeps exactly eight `export IWE_` lines.
if [ -d "$WORKSPACE_DIR/MC-sessions" ]; then
    IWE_SESSIONS_ROOT_TARGET="\$IWE_WORKSPACE/MC-sessions"
else
    IWE_SESSIONS_ROOT_TARGET=""
fi

# Issue #957: update.sh reruns this script with --quiet, so an IWE_SCRIPTS switch
# would pass without a word. Compare old and new values resolved, not as literals.
resolve_paths_literal() {
    local value="$1"
    # shellcheck disable=SC2016 # literal "$IWE_*" references, exactly as written in .iwe-paths
    case "$value" in
        '$IWE_WORKSPACE' | '$IWE_WORKSPACE'/*)
            value="$WORKSPACE_DIR${value#\$IWE_WORKSPACE}" ;;
        '$IWE_TEMPLATE' | '$IWE_TEMPLATE'/*)
            value="$TEMPLATE_DIR${value#\$IWE_TEMPLATE}" ;;
    esac
    printf '%s' "$value"
}
OLD_IWE_SCRIPTS=""
if [ -z "$HOST_OWNER_CONFLICT" ] && [ -f "$IWE_ENV_FILE" ]; then
    OLD_IWE_SCRIPTS=$(sed -n 's/^export IWE_SCRIPTS="\(.*\)"$/\1/p' "$IWE_ENV_FILE" | head -1)
fi

if [ -z "$HOST_OWNER_CONFLICT" ]; then
cat > "$IWE_ENV_FILE" <<IWEENV_EOF
# IWE environment variables
# Generated by install-iwe-paths.sh. Rerun setup-offline.sh / iwe-update to regenerate.
# Do not edit manually — changes will be lost.

export IWE_WORKSPACE="$WORKSPACE_DIR"
export IWE_ROOT="$WORKSPACE_DIR"
export IWE_TEMPLATE="$TEMPLATE_DIR"
export IWE_SCRIPTS="$IWE_SCRIPTS_TARGET"
export IWE_ROLES="\$IWE_TEMPLATE/roles"
export IWE_RUNTIME="\$IWE_WORKSPACE/.iwe-runtime"
export IWE_GOVERNANCE_REPO="$GOVERNANCE_REPO"
export IWE_SESSIONS_ROOT="$IWE_SESSIONS_ROOT_TARGET"
IWEENV_EOF

$QUIET || echo "  ✓ $IWE_ENV_FILE written (workspace=$WORKSPACE_DIR)"

if [ -n "$OLD_IWE_SCRIPTS" ]; then
    OLD_SCRIPTS_RESOLVED=$(resolve_paths_literal "$OLD_IWE_SCRIPTS")
    NEW_SCRIPTS_RESOLVED=$(resolve_paths_literal "$IWE_SCRIPTS_TARGET")
    if [ "$OLD_SCRIPTS_RESOLVED" != "$NEW_SCRIPTS_RESOLVED" ]; then
        # Deliberately not gated by --quiet: this is the case --quiet callers must see.
        echo "  ⚠ IWE_SCRIPTS: $OLD_SCRIPTS_RESOLVED → $NEW_SCRIPTS_RESOLVED"
        echo "    Рабочая scripts/ берётся, только если в ней обычный (не симлинк) session-guard.sh; иначе — scripts/ шаблона. Проверьте, что путь ожидаемый."
        echo "    Новое значение подхватят только новые оболочки и qwen после перезапуска."
    fi
fi

# Ensure each shell rc sources ~/.iwe-paths (idempotent)
for RC in "${RC_FILES[@]}"; do
    if [ -f "$RC" ] && grep -qF "$IWE_ENV_MARKER" "$RC"; then
        $QUIET || echo "  ○ $RC already sources \$HOME/.iwe-paths"
    else
        cat >> "$RC" <<'RC_EOF'

# IWE environment (WP-219, DP.FM.009): lookup-слой для путей к скриптам
[ -f "$HOME/.iwe-paths" ] && source "$HOME/.iwe-paths"
RC_EOF
        $QUIET || echo "  ✓ $RC → sources \$HOME/.iwe-paths"
    fi
done
fi

# Auto-enable pre-commit hooks for IWE repos that have .githooks/
# (Claude peer-review, 2026-05-26 — BFS3)
for repo_dir in "$WORKSPACE_DIR"/* "$WORKSPACE_DIR"/*/*; do
    [ -d "$repo_dir/.git" ] || continue
    [ -d "$repo_dir/.githooks" ] || continue
    if [ "$(git -C "$repo_dir" config --local core.hooksPath 2>/dev/null)" != ".githooks" ]; then
        git -C "$repo_dir" config --local core.hooksPath .githooks
        $QUIET || echo "  ✓ $repo_dir → core.hooksPath=.githooks"
    fi
done
