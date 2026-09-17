# Ручной запуск задач (offline / Windows / без планировщика)

> В этой ветке нет планировщика (launchd на macOS, cron на Linux, Task Scheduler на Windows).
> Всё, что в оригинальном IWE крутилось по расписанию, здесь запускается **руками** из git bash.
> Установщики расписания (`roles/*/install.sh`, `setup/optional/setup-cloud-scheduler.sh`,
> `scripts/setup-extractor-feeders.sh`) отключены заглушкой и просто отсылают сюда.

## Что раньше шло по расписанию

| Задача | Скрипт | Когда шла по расписанию | Зачем |
|--------|--------|--------------------------|-------|
| Утренний Стратег | `roles/strategist/scripts/strategist.sh` | каждое утро (Hour/Minute) | сбор данных за вчера, заготовка плана дня |
| Недельное ревью | `roles/strategist/scripts/strategist.sh` | раз в неделю | заготовка недельного ревью |
| Проверка inbox (Экстрактор) | `roles/extractor/scripts/extractor.sh` | по интервалу (StartInterval) | разбор входящих заметок |
| Центральный диспетчер | `roles/synchronizer/scripts/scheduler.sh` | 00:00 / 03:00 / утро | запуск дочерних задач, бэкапы, отчёты |
| Помодоро-напоминания | `setup/optional/pomodoro-alert.py` | по интервалу | напоминания о перерывах |

## Как запускать вручную

Открой git bash в корне рабочего каталога и запускай по необходимости:

```bash
# Утренняя заготовка плана дня (раньше — по расписанию утром)
bash roles/strategist/scripts/strategist.sh

# Разбор входящих заметок
bash roles/extractor/scripts/extractor.sh

# Дневной прогон диспетчера (бэкапы, отчёты, дочерние задачи)
bash roles/synchronizer/scripts/scheduler.sh
```

> Перед первым запуском один раз выполни `bash setup-offline.sh` —
> он подставит пути в шаблонные плейсхолдеры `{{...}}`.

## Что НЕ работает offline (и не нужно запускать)

- **Облачная телеметрия** (`.qwen/hooks/agent-trace-uploader.sh`, `scripts/iwe-trace.py`) —
  отправка в облако невозможна; локальные трейсы пишутся на диск и сохраняются.
- **Telegram-уведомления** (`scripts/fmt-critical-alert.sh`) — нет сети.
- **Google Calendar / News** (`scripts/server-calendar.sh`, `scripts/server-news.sh`) —
  отключены заглушкой, day-open работает без них.
- **MCP-серверы** (`.mcp.json`) — пусто, облачные знания недоступны offline.
- **Авто-обновление** (`update.sh`) — обновление только через скачивание ZIP-архива ветки
  (инструкция внутри `update.sh`).
- **Подтяжка репозиториев при первом касании** (`.qwen/hooks/pull-on-touch.sh`) — в
  `.qwen/settings.json` не подключена: без удалённого репозитория и сети каждая попытка
  ждала бы таймаута.
- **Обновление по расписанию утреннего плана** (`seed/strategy/scripts/day-open-pipeline.sh`
  и его помощники с Telegram) — ни одна роль его не запускает и в шаблоне; offline не нужно.

## Защита от утечки секретов: нужны jq и python3

Хуки `secret-leak-block`, `secret-file-read-block`, `secret-mcp-dump-guard` не дают агенту
прочитать или вывести секреты (`.env`, ключи, выгрузки токенов через MCP). Им нужны
**`jq`** и **`python3`**. В git bash на Windows `jq` по умолчанию нет — положите
`jq.exe` в каталог из `PATH` (например `~/bin`, его добавляет `setup-offline.sh`);
`python3` даёт обёртка из `setup-offline.sh` [4e].

Если зависимости нет, защита **выключается** (иначе хук блокировал бы каждую команду
агента, включая ту, что нужна для починки) и агент видит предупреждение
«Защита … выключена» при каждом вызове. Это сигнал поставить `jq`, а не игнорировать.

Хуки подключены через `.qwen/hooks/qwen-tool-name-shim.sh`: Qwen Code передаёт хуку имя
инструмента `run_shell_command`/`read_file`/…, а хуки шаблона ждут имён Claude
(`Bash`/`Read`/…). Без прослойки защита блокировала бы все вызовы.

## Версионирование

Локальный git без удалённого репозитория. Фиксируй прогресс обычными коммитами:

```bash
git add <конкретные-файлы>
git commit -m "..."
git log --oneline      # история для отката
```
