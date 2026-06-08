# Обновление ветки `qwen-windows-offline` из upstream

## Идея

Эта ветка — **детерминированная адаптация** main: ~95% отличий это механика
(переименование `CLAUDE.md`→`QWEN.md`, `.claude/`→`.qwen/`, строковые замены) плюс
небольшой набор «наших» файлов. Поэтому обновляемся **не через `git merge`**
(он давал бы конфликты на каждом апдейте), а через **регенерацию**: берём свежий
main и заново прогоняем `scripts/adapt-to-qwen-offline.sh`.

```
upstream → fork/main (как сейчас) → [adapt-to-qwen-offline.sh] → qwen-windows-offline
```

## Шаги

### 1. Обновить `main` из upstream (как сейчас)

Так же, как форк делал это раньше (коммиты «chore: update from upstream template vX.Y.Z»).
Например через апстримный `update.sh` на main, либо вручную. Итог: `origin/main`
содержит новую версию шаблона.

### 2. Регенерировать ветку из свежего main

```bash
git fetch origin

# свежая рабочая ветка от обновлённого main
git checkout -B qwen-next origin/main

# взять адаптер из текущей qwen-ветки (на main его нет) и запустить
git show origin/qwen-windows-offline:scripts/adapt-to-qwen-offline.sh > /tmp/adapt.sh
bash /tmp/adapt.sh --src origin/qwen-windows-offline

# проверить результат
git status
git diff --stat
```

Адаптер:
1. переименует `CLAUDE.md`/`.claude` → `QWEN.md`/`.qwen` (+ seed/skeleton);
2. прогонит строковые замены (URL-safe);
3. восстановит «наши» файлы дословно из старой ветки (`git show`);
4. вставит guard'ы «нет планировщика» (идемпотентно, по маркеру);
5. перенесёт блоки README/QWEN между маркерами.

### 3. Зафиксировать и опубликовать

```bash
git add -A
git commit -m "regen qwen-windows-offline from main vX.Y.Z"

# обновить ветку (история линейная — force; ветка генерируемая)
git branch -f qwen-windows-offline qwen-next
git checkout qwen-windows-offline
git push --force-with-lease origin qwen-windows-offline
git branch -D qwen-next
```

> `--force-with-lease` безопаснее `--force`: откажет, если кто-то успел запушить.
> Ветка регенерируемая, поэтому force здесь — норма, а не риск (история = main + детерминированный transform).

## Что является «source of truth»

- **Механика** (переименования/замены) — в самом адаптере. Меняешь правило →
  правишь адаптер, не 130 файлов руками.
- **Наши файлы** (`setup-offline.sh`, `.qwen/settings.json`, `update.sh`,
  `link-memory.sh`, `MANUAL-JOBS.md`, `MIGRATION.md`, `.gitattributes`,
  `.gitignore`, `setup/install-iwe-paths.sh` и др.) — их редактируешь прямо в
  ветке; адаптер восстанавливает их дословно (`OWNED` в адаптере).
- **Вставные блоки** README/QWEN — между маркерами `QWEN-OFFLINE:*`; редактируешь
  в ветке, адаптер переносит.

## Если upstream сломал «наш» файл

Например upstream сильно переписал `setup/install-iwe-paths.sh` (он у нас в
OWNED — восстанавливается дословно, апстрим-правки потеряются). После регенерации
сделай diff против main и реши, нужно ли перенести апстрим-изменения в наш файл:

```bash
git diff origin/main -- setup/install-iwe-paths.sh
```

Аналогично для guard'ованных скриптов (`roles/*/install.sh` и т.п.) — там апстрим-
правки СОХРАНЯЮТСЯ (берётся свежий файл + вставляется только guard-блок).

## Проверка после регенерации

```bash
bash -n setup-offline.sh scripts/link-memory.sh scripts/adapt-to-qwen-offline.sh
python3 -c "import json;json.load(open('.qwen/settings.json'));json.load(open('.mcp.json'))"
grep -rn 'CLAUDE_PROJECT_DIR' --include='*.sh' --include='*.json' . | grep -v CHANGELOG   # должно быть пусто
```
