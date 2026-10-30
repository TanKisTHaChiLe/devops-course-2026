#!/usr/bin/env bash
# Доставка сайта: scripts/deploy.sh [--dry-run]
set -euo pipefail

fail() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }

DRY_RUN=false
case "$#" in
  0) ;;
  1) [[ "$1" == '--dry-run' ]] || fail 'Использование: scripts/deploy.sh [--dry-run]'
     DRY_RUN=true ;;
  *) fail 'Использование: scripts/deploy.sh [--dry-run]' ;;
esac

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
REMOTE='devops'
REMOTE_DIR='/var/www/devops-site/'
LOCAL_DIR="$REPO_ROOT/site/"
SITE_URL='https://devops.local/'
# Только открытый сертификат, полученный через доверенное SSH-соединение.
CA_CERT="${CA_CERT:-$REPO_ROOT/certs/devops.crt}"

[[ -f "${LOCAL_DIR}index.html" ]] || fail 'Отсутствует site/index.html; доставка отменена.'
STATUS="$(git -C "$REPO_ROOT" status --porcelain --untracked-files=all)"
[[ -z "$STATUS" ]] || fail 'Есть незафиксированные изменения (включая индекс и новые файлы); доставка отменена.'
COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
if [[ "$DRY_RUN" == false ]]; then
  [[ -r "$CA_CERT" ]] || fail "Не найден доверенный сертификат: $CA_CERT"
fi

OPTIONS=(-avz --delete --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r --timeout=20)
if [[ "$DRY_RUN" == true ]]; then OPTIONS+=(--dry-run); fi
# Единственное SSH-соединение за запуск. Пароли не запрашиваются.
if ! rsync "${OPTIONS[@]}" \
  -e 'ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=yes' \
  "$LOCAL_DIR" "${REMOTE}:${REMOTE_DIR}"; then
  fail 'rsync не смог выполнить синхронизацию.'
fi

if [[ "$DRY_RUN" == true ]]; then
  printf 'Пробный запуск: сервер не изменён. Коммит: %s\n' "$COMMIT"
  exit 0
fi

# IPv4 соответствует Host-only сети; проверка TLS остаётся включённой.
if ! curl -4 --noproxy devops.local -fsS --cacert "$CA_CERT" \
  --connect-timeout 5 --max-time 15 -o /dev/null "$SITE_URL"; then
  fail 'Файлы переданы, но проверка доступности HTTPS не пройдена.'
fi
printf 'Деплой успешен. Коммит: %s\n' "$COMMIT"
