#!/bin/bash
# Exocortex Update — OFFLINE-режим (ветка qwen-windows-offline)
#
# Эта ветка работает без доступа к интернету. Автоматическое обновление из
# upstream (raw.githubusercontent.com) недоступно. Оригинальный сетевой
# update.sh заменён этой заглушкой.
#
# === Как обновляться без интернета ===
#
# 1. На машине с доступом к сети открой:
#       https://github.com/trover97/FMT-exocortex-template/tree/qwen-windows-offline
#    «Code» → «Download ZIP».
#
# 2. Перенеси ZIP на рабочую машину (флешка / общий диск).
#
# 3. Распакуй во временную папку и сравни с текущей установкой через git:
#       cd ~/IWE                     # твой рабочий каталог
#       git add -A && git commit -m "snapshot before update"   # зафиксируй текущее
#       # распакуй новый ZIP поверх (или в /tmp/new и скопируй вручную)
#       git status                   # посмотри что изменилось
#       git add -A && git commit -m "update from qwen-windows-offline ZIP"
#
#    Локальный git (без remote) хранит историю — всегда можно откатиться:
#       git log --oneline
#       git checkout <commit> -- <файл>
#
# 4. После обновления перезапусти подстановку плейсхолдеров, если менялись
#    шаблонные файлы:
#       bash setup-offline.sh
#
echo "update.sh: OFFLINE-режим — автообновление по сети отключено."
echo "Обновление через скачивание ZIP-архива ветки. Подробности — внутри этого файла."
exit 0
