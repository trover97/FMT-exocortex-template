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

## Версионирование

Локальный git без удалённого репозитория. Фиксируй прогресс обычными коммитами:

```bash
git add <конкретные-файлы>
git commit -m "..."
git log --oneline      # история для отката
```
