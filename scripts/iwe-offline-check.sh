#!/bin/bash
# iwe-offline-check.sh — проверка «IWE и Qwen Code не ходят в интернет» (qwen-windows-offline, цикл 14).
#
# ТОЛЬКО ЧИТАЕТ: ничего не пишет и не меняет. Значения из ~/.qwen/.env не печатает (там лежат ключи API),
# говорит лишь «есть / нет / значение не то». Запускать из git bash:
#   bash scripts/iwe-offline-check.sh          # проверить
#   bash scripts/iwe-offline-check.sh --help   # эта справка
#
# Что проверяет: выключатели Qwen в .qwen/settings.json, три строки в ~/.qwen/.env, заглушку хука конца
# сессии, версию qwen, а также что остаётся открытым (remote в хранилищах, ключи Telegram, MCP/расширения,
# системный прокси). Код выхода 1, если обязательный выключатель не найден.
# Переопределения для тестов: IWE_OFFLINE_ENV_FILE (путь к проверяемому .env), QWEN_HOME, IWE_ROOT.
set -euo pipefail

case "${1:-}" in
  --help|-h) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) echo "Неизвестный аргумент: $1 (см. --help)" >&2; exit 2 ;;
esac

FMT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS="${IWE_ROOT:-${IWE_WORKSPACE:-$(dirname "$FMT_DIR")}}"
QWEN_BASE="${QWEN_HOME:-${QWEN_RUNTIME_DIR:-$HOME/.qwen}}"
ENV_FILE="${IWE_OFFLINE_ENV_FILE:-$QWEN_BASE/.env}"
SETTINGS="$WS/.qwen/settings.json"

NO=0; WARN=0
ok()   { printf '  [есть]  %s\n' "$1"; }
bad()  { printf '  [НЕТ]   %s\n' "$1"; NO=$((NO + 1)); }
warn() { printf '  [внимание] %s\n' "$1"; WARN=$((WARN + 1)); }

echo "=== Проверка запрета интернета (только чтение) ==="
echo "Рабочая папка: $WS"
echo "Каталог Qwen:  $QWEN_BASE"

# Домашняя папка Windows может отличаться от HOME в git bash: Qwen берёт Windows-форму.
if command -v cygpath >/dev/null 2>&1 && [ -n "${USERPROFILE:-}" ]; then
  up="$(cygpath -u "$USERPROFILE" 2>/dev/null || true)"
  if [ -n "$up" ] && [ "$(printf '%s' "$up" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$HOME" | tr '[:upper:]' '[:lower:]')" ]; then
    warn "HOME в git bash ($HOME) не совпадает с домашней папкой Windows ($up): Qwen ищет .env в Windows-папке"
  fi
fi

echo; echo "[1] Выключатели Qwen в .qwen/settings.json"
PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys' >/dev/null 2>&1; then PY="$c"; break; fi
done
if [ ! -f "$SETTINGS" ]; then
  bad "нет файла $SETTINGS (запустите bash update.sh)"
elif [ -z "$PY" ]; then
  warn "не найден Python: разберите $SETTINGS вручную (ключи перечислены в MANUAL-JOBS.md, раздел «Запрет интернета»)"
else
  report="$("$PY" - "$SETTINGS" <<'PYEOF'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8-sig"))
except Exception:
    print("ERR"); sys.exit(0)
def g(path):
    cur = d
    for k in path.split("."):
        if not isinstance(cur, dict) or k not in cur:
            return None
        cur = cur[k]
    return cur
for p in ("privacy.usageStatisticsEnabled", "general.enableAutoUpdate", "general.batchAutoCollect",
          "ui.enableUserFeedback", "ide.enabled", "tools.webSearch.enabled"):
    print(p, "ok" if g(p) is False else "no")
deny = g("permissions.deny") or []
for t in ("WebFetch", "WebSearch"):
    print("permissions.deny:" + t, "ok" if t in deny else "no")
print("mcpServers", "yes" if g("mcpServers") else "no")
PYEOF
)"
  if [ "$report" = "ERR" ]; then
    bad "$SETTINGS не разбирается как JSON"
  else
    while IFS=' ' read -r key state; do
      case "$key" in
        mcpServers) [ "$state" = "yes" ] && warn "в настройках проекта заданы MCP-серверы: их выходы в сеть Qwen не контролирует" ;;
        *) if [ "$state" = "ok" ]; then ok "$key"; else bad "$key"; fi ;;
      esac
    done <<< "$report"
  fi
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

echo; echo "[3] Хук конца сессии (единственный автоматический сетевой выход ветки)"
SES="$WS/.qwen/hooks/session-end-status.sh"
if [ ! -f "$SES" ]; then
  warn "нет файла $SES"
elif grep -q 'OFFLINE GUARD' "$SES"; then
  ok "хук session-end-status заглушён (запись статуса в базу не выполняется)"
else
  bad "хук session-end-status без заглушки: при наличии файла секретов и psql он пишет в базу Neon"
fi

echo; echo "[4] Версия и окружение"
if command -v qwen >/dev/null 2>&1; then
  ver="$(qwen --version 2>/dev/null | head -n 1 || true)"
  ok "qwen --version: ${ver:-не определилась}"
else
  warn "qwen не найден в PATH этого git bash (версию смотрите там, откуда запускаете Qwen)"
fi
for v in HTTPS_PROXY HTTP_PROXY ALL_PROXY https_proxy http_proxy; do
  if [ -n "${!v:-}" ]; then
    warn "задан системный $v (значение не печатаю): запросы Qwen и скриптов пойдут через этот прокси; убедитесь, что это намеренно"
  fi
done

echo; echo "[5] Что остаётся открытым"
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
echo "  ssh у iwe-grep-secret.sh, новые выходы будущих версий Qwen. Жёстко закрыл бы брандмауэр (нужны права администратора)."

echo; echo "[6] Сверка по трафику (руками, после каждого обновления Qwen)"
echo "  Запустите Qwen из корня рабочей папки и из подпапки хранилища, сделайте один обмен с моделью, затем:"
echo "    tasklist | findstr /i node        # PID процессов node"
echo "    netstat -ano | findstr ESTABLISHED # соединения этих PID: должен остаться только адрес модели"

echo
if [ "$NO" -gt 0 ]; then
  echo "Итог: не хватает $NO обязательных пунктов, предупреждений $WARN."
  exit 1
fi
echo "Итог: обязательные пункты на месте, предупреждений $WARN."
