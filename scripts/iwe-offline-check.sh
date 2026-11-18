#!/bin/bash
# iwe-offline-check.sh — проверка «IWE и Qwen Code не ходят в интернет» (qwen-macos-offline).
#
# ТОЛЬКО ЧИТАЕТ: ничего не пишет и не меняет. Значения из ~/.qwen/.env не печатает (там лежат ключи API),
# говорит лишь «есть / нет / значение не то». Запускать из macOS:
#   bash scripts/iwe-offline-check.sh          # проверить
#   bash scripts/iwe-offline-check.sh --help   # эта справка
#
# Что проверяет: действующие (эффективные) выключатели Qwen на всех четырёх слоях настроек —
# System Defaults → User (~/.qwen/settings.json) → Workspace ($cwd/.qwen/settings.json) → System
# (system применяется последним). Два вердикта: запуск из корня workspace и из подпапки
# (в подпапке проектный слой не действует — Qwen ищет workspace-settings только в точном cwd).
# Дальше: три строки в ~/.qwen/.env, одобрение хуков проекта или доверие к папке (иначе Qwen работает без них),
# заглушка хука конца сессии, версия qwen, QWEN_CODE_MEMORY_LOCAL,
# а также что остаётся открытым (remote в хранилищах, Telegram, MCP/расширения, прокси).
# Код выхода 1, если хотя бы один вердикт или обязательный пункт не прошёл.
# Переопределения для тестов: IWE_OFFLINE_ENV_FILE, IWE_OFFLINE_SETTINGS_PATHS (пути слоёв через ':'),
# QWEN_HOME, IWE_ROOT.
set -euo pipefail

case "${1:-}" in
  --help|-h) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) echo "Неизвестный аргумент: $1 (см. --help)" >&2; exit 2 ;;
esac

FMT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS="${IWE_ROOT:-${IWE_WORKSPACE:-$(dirname "$FMT_DIR")}}"
case "$WS" in /) ;; */) WS="${WS%/}" ;; esac
QWEN_BASE="${QWEN_HOME:-${QWEN_RUNTIME_DIR:-$HOME/.qwen}}"
ENV_FILE="${IWE_OFFLINE_ENV_FILE:-$QWEN_BASE/.env}"

# Слои настроек (порядок = порядок применения, system последний).
SYSTEM_SETTINGS="${QWEN_CODE_SYSTEM_SETTINGS_PATH:-/Library/Application Support/QwenCode/settings.json}"
SYSTEM_DEFAULTS="${QWEN_CODE_SYSTEM_DEFAULTS_PATH:-$(dirname "$SYSTEM_SETTINGS")/system-defaults.json}"
USER_SETTINGS="$QWEN_BASE/settings.json"
LAYER_PATHS="$SYSTEM_DEFAULTS:$USER_SETTINGS:$SYSTEM_SETTINGS"
[ -n "${IWE_OFFLINE_SETTINGS_PATHS:-}" ] && LAYER_PATHS="$IWE_OFFLINE_SETTINGS_PATHS"

# Подпапка для второго вердикта: первый подкаталог workspace с .git (запуск изнутри хранилища),
# иначе просто seed/ — файл .qwen/settings.json заведомо отсутствует.
SUBDIR=""
for d in "$WS"/*/; do
  [ -d "$d" ] || continue
  if [ -e "${d}.git" ]; then SUBDIR="${d%/}"; break; fi
done
[ -n "$SUBDIR" ] || { [ -d "$WS/seed" ] && SUBDIR="$WS/seed"; }
[ -n "$SUBDIR" ] || SUBDIR="$WS/.qwen"

NO=0; WARN=0
ok()   { printf '  [есть]  %s\n' "$1"; }
bad()  { printf '  [НЕТ]   %s\n' "$1"; NO=$((NO + 1)); }
warn() { printf '  [внимание] %s\n' "$1"; WARN=$((WARN + 1)); }

echo "=== Проверка запрета интернета (только чтение) ==="
echo "Рабочая папка: $WS"
echo "Каталог Qwen:  $QWEN_BASE"

PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys' >/dev/null 2>&1; then PY="$c"; break; fi
done

echo; echo "[1] Эффективные выключатели по слоям настроек"
echo "    System Defaults: $SYSTEM_DEFAULTS"
echo "    User:            $USER_SETTINGS"
echo "    System:          $SYSTEM_SETTINGS"
if [ -z "$PY" ]; then
  warn "не найден Python: разберите слои вручную (ключи — в MANUAL-JOBS.md, раздел «Запрет интернета»)"
else
  verdict="$("$PY" - "$WS" "$SUBDIR" "$LAYER_PATHS" <<'PYEOF'
import json, os, sys

workspace, subdir, layer_paths = sys.argv[1], sys.argv[2], sys.argv[3].split(":")
system_defaults, user_settings, system_settings = layer_paths[:3]

def load(path):
    """(state, data): missing | bad | ok."""
    if not path or not os.path.exists(path):
        return "missing", {}
    try:
        with open(path, encoding="utf-8-sig") as f:
            data = json.load(f)
    except Exception:
        return "bad", {}
    if not isinstance(data, dict):
        return "bad", {}
    return "ok", data

def deep_merge(base, overlay):
    out = dict(base)
    for k, v in overlay.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = deep_merge(out[k], v)
        else:
            out[k] = v
    return out

def get(d, dotted):
    cur = d
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur

SWITCHES = (
    "privacy.usageStatisticsEnabled",
    "general.enableAutoUpdate",
    "general.batchAutoCollect",
    "ui.enableUserFeedback",
    "ide.enabled",
    "tools.webSearch.enabled",
)

def effective(cwd):
    """Слои в порядке применения; workspace-слой — только из точного cwd."""
    names = ["system-defaults", "user", "workspace:" + cwd, "system"]
    paths = [system_defaults, user_settings, os.path.join(cwd, ".qwen", "settings.json"), system_settings]
    merged, states, deny = {}, [], set()
    for name, path in zip(names, paths):
        state, data = load(path)
        states.append((name, state))
        if state != "ok":
            continue
        merged = deep_merge(merged, data)
        # permissions.deny проверяем объединением всех слоёв: правило действует,
        # если его объявил хотя бы один источник (консервативно для офлайн-проверки).
        for tool in (get(data, "permissions.deny") or []):
            deny.add(tool)
    return merged, states, deny

def report(label, cwd):
    merged, states, deny = effective(cwd)
    print("VERDICT " + label)
    problems = 0
    for name, state in states:
        if state == "bad":
            print("  BADJSON " + name)
            problems += 1
    for sw in SWITCHES:
        val = get(merged, sw)
        if val is False:
            print("  OK " + sw)
        else:
            print("  FAIL " + sw + ("" if val is None else " (значение задано не false)"))
            problems += 1
    for tool in ("WebFetch", "WebSearch"):
        if tool in deny:
            print("  OK permissions.deny:" + tool)
        else:
            print("  FAIL permissions.deny:" + tool)
            problems += 1
    active = "workspace" if any(get(merged, sw) is not None for sw in SWITCHES) else "none"
    print("  ACTIVE " + active)
    print("  PROBLEMS %d" % problems)

report("корень", workspace)
if os.path.normpath(subdir) != os.path.normpath(workspace):
    report("подпапка", subdir)
PYEOF
)"
  cur_label=""
  while IFS= read -r line; do
    case "$line" in
      "VERDICT "*)
        cur_label="${line#VERDICT }"
        echo
        echo "  --- Запуск из $cur_label ($([ "$cur_label" = "корень" ] && echo "$WS" || echo "$SUBDIR")) ---"
        ;;
      "  OK "*)   ok "${line#  OK }" ;;
      "  FAIL "*) bad "${line#  FAIL }" ;;
      "  BADJSON "*) bad "слой ${line#  BADJSON } не разбирается как JSON" ;;
      "  ACTIVE "*) : ;;
      "  PROBLEMS "*) : ;;
      *) ;;
    esac
  done <<< "$verdict"
fi

echo; echo "[2] Три строки в ~/.qwen/.env (значения не печатаются)"
env_state() { # KEY EXPECTED → ok | wrong | missing
  local line v
  [ -f "$ENV_FILE" ] || { echo missing; return 0; }
  line="$(tr -d '\r' < "$ENV_FILE" | grep -E "^[[:space:]]*(export[[:space:]]+)?$1=" | tail -n 1 || true)"
  [ -n "$line" ] || { echo missing; return 0; }
  v="${line#*=}"; v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
  if [ "$v" = "$2" ]; then echo ok; else echo wrong; fi
}
if [ ! -f "$ENV_FILE" ]; then
  bad "файла $ENV_FILE нет: создайте его и добавьте три строки (см. MANUAL-JOBS.md)"
else
  for pair in QWEN_USAGE_STATISTICS_ENABLED=0 QWEN_CODE_MODELS_DEV=off QWEN_CODE_DISABLE_PRECONNECT=1; do
    k="${pair%%=*}"; want="${pair#*=}"
    case "$(env_state "$k" "$want")" in
      ok) ok "$k" ;;
      wrong) bad "$k задан, но значение не то (ждём то, что в MANUAL-JOBS.md)" ;;
      *) bad "$k не задан" ;;
    esac
  done
fi

echo; echo "[3] Хуки проекта: одобрение и доверие к папке"
# Qwen 0.27.2 не запускает хуки из проектного слоя до явного решения: одобрение ровно того
# набора хуков (hookApprovals.json) или явное доверие к папке (security.folderTrust +
# trustedFolders.json). Одобрение привязано к хешу набора хуков и проектного окружения,
# поэтому после update.sh, правки хуков или .env в рабочей папке Qwen спросит снова.
# Без этого запрет чтения секретов и напоминания ритуалов молча не работают.
if [ -z "$PY" ]; then
  bad "не найден Python: состояние хуков НЕ проверено (это не «одобрено»). Поставьте python3 (xcode-select --install) и повторите"
else
HOOK_STATE="$("$PY" - "$WS" "$USER_SETTINGS" "$SYSTEM_DEFAULTS" "$SYSTEM_SETTINGS" <<'PYEOF'
import hashlib, json, os, re, sys

ws, user_settings, system_defaults, system_settings = sys.argv[1:5]


def qwen_global_dir():
    # Qwen хранит одобрения и доверие в глобальном каталоге (QWEN_HOME или ~/.qwen),
    # а не в QWEN_RUNTIME_DIR.
    return os.environ.get("QWEN_HOME") or os.path.join(os.path.expanduser("~"), ".qwen")


def load_json(path):
    if not path or not os.path.exists(path):
        return "missing", {}
    try:
        with open(path, encoding="utf-8-sig") as fh:
            data = json.load(fh)
    except Exception:
        return "bad", {}
    if not isinstance(data, dict):
        return "bad", {}
    return "ok", data


def dig(data, dotted):
    cur = data
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur


def merge(base, overlay):
    out = dict(base)
    for key, value in overlay.items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = merge(out[key], value)
        else:
            out[key] = value
    return out


def folder_trust_enabled():
    # Включатель читается только из пользовательского/системного слоёв: проектный
    # settings.json его включить не может (Qwen игнорирует это значение из workspace).
    merged = {}
    for path in (system_defaults, user_settings, system_settings):
        state, data = load_json(path)
        if state == "ok":
            merged = merge(merged, data)
    return dig(merged, "security.folderTrust.enabled") is True


def real(path):
    try:
        return os.path.realpath(path)
    except OSError:
        return None


def trust_decision(root):
    """True/False/None по правилам trustedFolders.json: побеждает самый глубокий путь,
    при равенстве глубины побеждает отказ (как в Qwen)."""
    path = os.environ.get("QWEN_CODE_TRUSTED_FOLDERS_PATH") or os.path.join(
        qwen_global_dir(), "trustedFolders.json")
    state, rules = load_json(path)
    winner, depth = None, -1
    for rule_path, level in rules.items():
        if level == "TRUST_PARENT":
            base, trust = os.path.dirname(rule_path), True
        elif level == "TRUST_FOLDER":
            base, trust = rule_path, True
        elif level == "DO_NOT_TRUST":
            base, trust = rule_path, False
        else:
            continue
        base = real(base)
        if base is None or not (root == base or root.startswith(base + os.sep)):
            continue
        here = base.count(os.sep)
        if here > depth or (here == depth and not trust and winner is not False):
            winner, depth = trust, here
    return winner


def parse_dotenv(text):
    """Разбор .env как у npm dotenv: KEY=VALUE, кавычки, комментарии, export."""
    out = {}
    if text.startswith("﻿"):
        text = text[1:]
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        match = re.match(r"^(?:export\s+)?([\w.-]+)\s*=\s*(.*)$", line)
        if not match:
            continue
        key, value = match.group(1), match.group(2).strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            quote, value = value[0], value[1:-1]
            if quote == '"':
                value = (value.replace("\\n", "\n").replace("\\r", "\r")
                              .replace('\\"', '"').replace("\\\\", "\\"))
        else:
            cut = value.find(" #")
            if cut >= 0:
                value = value[:cut].rstrip()
        out[key] = value
    return out


def project_env_files(root):
    """Файлы, которые Qwen включает в хеш одобрения: (уверены?, {путь: значения}).
    Берётся первый найденный при подъёме от рабочей папки .qwen/.env или .env."""
    found = None
    cur = root
    while True:
        for candidate in (os.path.join(cur, ".qwen", ".env"), os.path.join(cur, ".env")):
            if os.path.isfile(candidate):
                found = candidate
                break
        if found or os.path.dirname(cur) == cur:
            break
        cur = os.path.dirname(cur)
    if not found:
        return True, {}
    real_found = real(found)
    if real_found is None:
        return False, {}
    if not (real_found == root or real_found.startswith(root + os.sep)):
        return True, {}  # файл вне рабочей папки Qwen в хеш не берёт
    try:
        with open(real_found, encoding="utf-8") as fh:
            text = fh.read()
    except Exception:
        return False, {}
    return True, {real_found: parse_dotenv(text)}


def hash_project_hooks(hooks, env):
    stable = json.dumps({"hooks": hooks, "env": env}, sort_keys=True,
                        separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(stable.encode("utf-8")).hexdigest()


def approval_state(root, hooks, settings):
    path = os.environ.get("QWEN_CODE_HOOK_APPROVALS_PATH") or os.path.join(
        qwen_global_dir(), "hookApprovals.json")
    _, records = load_json(path)
    record = None
    for record_path, value in records.items():
        if real(record_path) == root and isinstance(value, dict):
            record = value
    sure, files = project_env_files(root)
    if not sure:
        return "unknown"
    expected = hash_project_hooks(hooks, {"files": files, "settings": settings.get("env")})
    if not record or record.get("hash") != expected:
        return "pending"
    status = record.get("status")
    return status if status in ("approved", "rejected") else "pending"


def main():
    root = real(ws)
    state, settings = load_json(os.path.join(root, ".qwen", "settings.json"))
    hooks = settings.get("hooks") if state == "ok" else None
    if not isinstance(hooks, dict) or not hooks:
        return "nohooks"
    enabled = folder_trust_enabled()
    trust = trust_decision(root) if enabled else None
    approval = approval_state(root, hooks, settings)
    # Qwen при включённом доверии и недоверенной папке не загружает проектные
    # настройки целиком, поэтому проверка доверия идёт первой.
    if enabled and trust is not True:
        return "bad-untrusted"
    if approval == "approved":
        return "ok-approved"
    if approval == "rejected":
        return "bad-rejected"
    if approval == "pending":
        return "ok-trust" if (enabled and trust is True) else "bad-pending"
    return "bad-unknown"


try:
    print(main())
except Exception:
    print("error")
PYEOF
)"
case "$HOOK_STATE" in
  nohooks)       ok "в .qwen/settings.json нет хуков проекта: одобрять нечего" ;;
  ok-approved)   ok "одобрение совпадает с текущим набором хуков (hookApprovals.json): хуки проекта работают" ;;
  ok-trust)      ok "папка явно доверена (security.folderTrust + trustedFolders.json): хуки проекта работают без отдельного одобрения" ;;
  bad-untrusted) bad "доверие к папкам включено, но $WS не доверена: Qwen не загрузит проектные настройки, хуки не работают. Отметьте папку доверенной в qwen (/permissions) или в trustedFolders.json" ;;
  bad-rejected)  bad "хуки отклонены для этой папки: Qwen не спросит снова, пока набор хуков не изменится. Удалите запись из hookApprovals.json и откройте /hooks или перезапустите qwen" ;;
  bad-pending)   bad "одобрения нет или оно устарело (менялись хуки, .env или env в настройках): Qwen работает без них, запрет чтения секретов и напоминания не действуют. Запустите qwen из $WS и ответьте «одобрить» (второй путь - security.folderTrust, см. MANUAL-JOBS.md)" ;;
  bad-unknown)   bad "не удалось сверить одобрение с текущими хуками (не разобрался проектный .env): проверьте вручную, откройте qwen из $WS и посмотрите /hooks" ;;
  *)             bad "состояние хуков не определилось: откройте qwen из $WS и посмотрите /hooks" ;;
esac
fi

echo; echo "[4] Хук конца сессии (единственный автоматический сетевой выход ветки)"
SES="$WS/.qwen/hooks/session-end-status.sh"
if [ ! -f "$SES" ]; then
  warn "нет файла $SES"
elif grep -q 'OFFLINE GUARD' "$SES"; then
  ok "хук session-end-status заглушён (запись статуса в базу не выполняется)"
else
  bad "хук session-end-status без заглушки: при наличии файла секретов и psql он пишет в базу Neon"
fi

echo; echo "[5] Версия и окружение"
if command -v qwen >/dev/null 2>&1; then
  ver="$(qwen --version 2>/dev/null | head -n 1 || true)"
  ok "qwen --version: ${ver:-не определилась}"
  echo "  ℹ  ожидаемая версия контрактов ветки: 0.27.2"
else
  warn "qwen не найден в PATH этого терминала (версию смотрите там, откуда запускаете Qwen)"
fi
if [ "${QWEN_CODE_MEMORY_LOCAL:-}" = "1" ]; then
  bad "QWEN_CODE_MEMORY_LOCAL=1: память уедет в <project>/.qwen/memory, единый каталог памяти сломается"
fi
for v in HTTPS_PROXY HTTP_PROXY ALL_PROXY https_proxy http_proxy; do
  if [ -n "${!v:-}" ]; then
    warn "задан системный $v (значение не печатаю): запросы Qwen и скриптов пойдут через этот прокси; убедитесь, что это намеренно"
  fi
done

echo; echo "[6] Что остаётся открытым"
for d in "$WS"/*/; do
  if [ -e "${d}.git" ]; then
    remotes="$(git -C "$d" remote 2>/dev/null | tr '\n' ' ' || true)"
    if [ -n "${remotes// /}" ]; then
      warn "в $(basename "$d") есть remote (${remotes% }): git fetch/push и роли стратега могут обращаться в сеть"
    fi
  fi
done
if [ -f "$HOME/.config/aist/env" ]; then
  warn "есть ~/.config/aist/env: ручные роли могут отправлять сообщения в Telegram"
fi
if [ -d "$QWEN_BASE/extensions" ] && [ -n "$(ls -A "$QWEN_BASE/extensions" 2>/dev/null || true)" ]; then
  warn "установлены расширения Qwen ($QWEN_BASE/extensions): у них свои обновления и выходы в сеть"
fi
echo "  Не закрыто переключателями: команды, которые модель запускает в shell (curl, npm, git),"
echo "  ssh у iwe-grep-secret.sh, фоновые подсистемы qwen 0.27 (daemon/ACP по умолчанию выключены),"
echo "  новые выходы будущих версий Qwen. Жёстко закрыл бы брандмауэр (pf/Packet Filter, нужны права администратора)."

echo; echo "[7] Сверка по трафику (руками, после каждого обновления Qwen)"
echo "  Запустите Qwen из корня рабочей папки и из подпапки хранилища, сделайте один обмен с моделью, затем:"
echo "    lsof -nP -iTCP -sTCP:ESTABLISHED | grep -Ei 'node|qwen'"
echo "      # в выводе должен остаться только адрес вашей модели (localhost/локальная сеть)"
echo "    nettop -P -L 1 -x 2>/dev/null | head -30   # запасной вариант, шире по охвату"
echo "  Снимок lsof — дополнительное наблюдение, а не доказательство: он не ловит завершённые"
echo "  соединения, UDP и DNS."

echo
if [ "$NO" -gt 0 ]; then
  echo "Итог: не хватает $NO обязательных пунктов, предупреждений $WARN."
  exit 1
fi
echo "Итог: обязательные пункты на месте, предупреждений $WARN."
