#!/usr/bin/env bash
# Brooke → Vercel одной командой.
# Запуск из Git Bash в папке Brooke:   bash deploy-vercel.sh
# Повторный запуск безопасен: он просто опубликует свежую версию.

set -u
cd "$(dirname "$0")" || exit 1

say()  { printf '\n\033[1;33m▶ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }
fail() { printf '\n\033[1;31m✗ %s\033[0m\n\n' "$*"; exit 1; }

[ -f vercel.json ] && [ -f web/index.html ] || fail "Запусти скрипт из папки Brooke (там, где лежат vercel.json и папка web)."

# ---------------------------------------------------------------- 1. Git
say "1/6 Сохраняю изменения в GitHub"
if [ -d .git ]; then
  git add -A >/dev/null 2>&1
  if ! git diff --cached --quiet 2>/dev/null; then
    git commit -q -m "Brooke: обновление $(date '+%Y-%m-%d %H:%M')" && ok "Изменения сохранены"
  else
    ok "Новых изменений нет"
  fi
  if git push -q 2>/dev/null; then ok "Загружено в GitHub"; else note "(git push не получился — продолжаю, сайт всё равно опубликуется)"; fi
else
  note "(папка не связана с git — пропускаю)"
fi

# ---------------------------------------------------------------- 2. Node.js
say "2/6 Проверяю Node.js"
if ! command -v node >/dev/null 2>&1; then
  note "Node.js не найден — устанавливаю через winget…"
  winget install -e --id OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements \
    || fail "Не удалось установить Node.js. Скачай его с nodejs.org (кнопка LTS) и запусти скрипт снова."
  fail "Node.js установлен. Закрой Git Bash, открой заново в папке Brooke и снова запусти: bash deploy-vercel.sh"
fi
ok "Node.js $(node -v)"

# ---------------------------------------------------------------- 3. Vercel CLI
say "3/6 Проверяю Vercel CLI"
if ! command -v vercel >/dev/null 2>&1; then
  note "Устанавливаю Vercel CLI (около минуты)…"
  npm install -g vercel || fail "Не удалось установить Vercel CLI. Пришли текст ошибки выше."
  hash -r
fi
command -v vercel >/dev/null 2>&1 \
  || fail "Vercel CLI установлен, но Git Bash его не видит. Закрой и открой Git Bash, потом снова: bash deploy-vercel.sh"
ok "$(vercel --version 2>/dev/null | tail -n 1)"

# ---------------------------------------------------------------- 4. Login
say "4/6 Вход в Vercel"
if ! vercel whoami >/dev/null 2>&1; then
  note "Сейчас откроется браузер. Войди через GitHub (Continue with GitHub) и подтверди."
  note "Если браузер не открылся — открой ссылку, которую Vercel покажет ниже."
  vercel login || fail "Вход не удался. Запусти скрипт снова."
fi
ok "Вошёл как $(vercel whoami 2>/dev/null | tail -n 1)"

# ---------------------------------------------------------------- 5. Project
say "5/6 Создаю проект «brooke»"
if [ ! -f .vercel/project.json ]; then
  vercel link --yes --project brooke >/dev/null 2>&1 \
    || vercel link --yes \
    || fail "Не удалось создать проект на Vercel. Пришли текст ошибки выше."
fi
ok "Проект готов"
# "already connected" also exits with 1, so check the text too
GIT_OUT=$(vercel git connect --yes 2>&1)
if [ $? -eq 0 ] || printf '%s' "$GIT_OUT" | grep -qi 'already connected'; then
  ok "GitHub подключён: каждый git push сам обновит сайт"
else
  note "(Автообновление по git push не подключилось. Ничего страшного:"
  note " после изменений просто запускай снова: bash deploy-vercel.sh)"
fi

# ---------------------------------------------------------------- 6. Deploy
say "6/6 Публикую сайт"
LOG=$(mktemp)
vercel deploy --prod --yes >"$LOG.out" 2>"$LOG"
DEPLOY_URL=$(grep -oE 'https://[A-Za-z0-9.-]+\.vercel\.app' "$LOG.out" | tail -n 1)
if [ -z "$DEPLOY_URL" ]; then
  cat "$LOG" "$LOG.out"
  fail "Публикация не удалась. Пришли текст выше."
fi

# Short permanent address (alias) instead of the long one-off deployment URL.
# The team alias (brooke-<user>.vercel.app) is behind Vercel login, so take
# the shortest alias that actually opens without it (HTTP 200).
DEPLOY_HOST=${DEPLOY_URL#https://}
SITE=""
for U in $(vercel inspect "$DEPLOY_URL" 2>&1 \
  | grep -oE 'https://[A-Za-z0-9.-]+\.vercel\.app' \
  | grep -v -F "$DEPLOY_HOST" \
  | awk '{ print length($0), $0 }' | sort -n | cut -d' ' -f2 | uniq); do
  if [ "$(curl -s -o /dev/null -w '%{http_code}' "$U/" 2>/dev/null)" = "200" ]; then SITE=$U; break; fi
done
[ -n "$SITE" ] || SITE=$DEPLOY_URL
rm -f "$LOG" "$LOG.out"

WAKE="$SITE/?wake=1"
echo "$SITE" > brooke-url.txt
if command -v clip >/dev/null 2>&1; then printf '%s' "$WAKE" | clip; COPIED=" (уже скопирована — вставляй в «Команды»)"; else COPIED=""; fi

printf '\n\033[1;32m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n'
printf '\033[1;32m  ✅ Brooke опубликован на Vercel\033[0m\n\n'
printf '  Сайт:                  \033[1m%s\033[0m\n' "$SITE"
printf '  Ссылка для будильника: \033[1m%s\033[0m%s\n' "$WAKE" "$COPIED"
printf '\033[1;32m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n\n'
note "Адрес также сохранён в файл brooke-url.txt."
note "Отправь ссылку себе в Telegram и открой её на iPhone в Safari."
