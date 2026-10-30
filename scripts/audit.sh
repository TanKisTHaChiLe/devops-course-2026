#!/usr/bin/env bash
# Запускать в Ubuntu: bash scripts/audit.sh
# Отрицательный тест сертификата: CERT_MIN_SECONDS=34560000 bash scripts/audit.sh
set -uo pipefail
export LC_ALL=C
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
PASS=0
FAIL=0
CERT_MIN_SECONDS="${CERT_MIN_SECONDS:-2592000}"

check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        printf ' [OK] %s\n' "$desc"
        PASS=$((PASS + 1))
    else
        printf " [FAIL] %s (ожидалось: '%s', получено: '%s')\n" "$desc" "$expected" "$actual"
        FAIL=$((FAIL + 1))
    fi
}

if [[ ! "$CERT_MIN_SECONDS" =~ ^[0-9]+$ ]]; then
    echo 'Ошибка: CERT_MIN_SECONDS должен быть целым неотрицательным числом.' >&2
    exit 1
fi
if (( EUID != 0 )) && ! sudo -v; then
    echo 'Ошибка: для проверки конфигурации нужны права sudo.' >&2
    exit 1
fi
as_root() {
    if (( EUID == 0 )); then "$@"; else sudo -n "$@"; fi
}

printf 'Аудит конфигурации: %s, %s\n' "$(hostname -f)" "$(date '+%Y-%m-%d %H:%M')"
echo '[1] Служба SSH'
SSH_CONFIG="$(as_root sshd -T 2>/dev/null)" || SSH_CONFIG=''
check 'Вход root запрещён' 'no' "$(awk '$1=="permitrootlogin"{print $2}' <<< "$SSH_CONFIG")"
check 'Парольная аутентификация отключена' 'no' "$(awk '$1=="passwordauthentication"{print $2}' <<< "$SSH_CONFIG")"
PORTS="$(awk '$1=="port"{print $2}' <<< "$SSH_CONFIG")"
PORT_OK=no
if [[ -n "$PORTS" ]] && ! grep -qx '22' <<< "$PORTS"; then PORT_OK=yes; fi
check 'SSH не использует порт 22' 'yes' "$PORT_OK"
check 'MaxAuthTries равно 3' '3' "$(awk '$1=="maxauthtries"{print $2}' <<< "$SSH_CONFIG")"

echo '[2] Межсетевой экран'
UFW_STATUS="$(as_root ufw status verbose 2>/dev/null)" || UFW_STATUS=''
check 'Межсетевой экран активен' 'active' "$(awk '/^Status:/{print $2}' <<< "$UFW_STATUS")"
check 'Входящий трафик по умолчанию запрещён' 'deny' \
    "$(sed -n 's/^Default: \([^ ]*\) (incoming).*/\1/p' <<< "$UFW_STATUS")"

echo '[3] Учётные записи'
awk -F: '$3>=1000 && $3<65534 {printf " %s (uid=%s)\n",$1,$3}' /etc/passwd

echo '[4] Веб-сервер'
NGINX_STATE="$(systemctl is-active nginx 2>/dev/null)" || :
check 'Служба nginx активна' 'active' "$NGINX_STATE"
if as_root nginx -t; then NGINX_RC=0; else NGINX_RC=$?; fi
check 'Конфигурация nginx корректна' '0' "$NGINX_RC"

if openssl x509 -in /etc/ssl/certs/devops.crt -noout \
    -checkend "$CERT_MIN_SECONDS" >/dev/null 2>&1; then CERT_RC=0; else CERT_RC=$?; fi
check "Сертификат действителен ещё минимум $CERT_MIN_SECONDS секунд" '0' "$CERT_RC"

PERMISSIONS_OK=yes
if [[ ! -d /var/www/devops-site ]]; then
    echo ' Каталог сайта отсутствует.'
    PERMISSIONS_OK=no
elif WORLD_WRITABLE="$(as_root find /var/www/devops-site -perm -o+w)"; then
    if [[ -n "$WORLD_WRITABLE" ]]; then
        printf ' Доступно для записи всем:\n%s\n' "$WORLD_WRITABLE"
        PERMISSIONS_OK=no
    fi
else
    PERMISSIONS_OK=no
fi
KEY_MODE="$(as_root stat -c '%a' /etc/ssl/private/devops.key 2>/dev/null)" || KEY_MODE='недоступен'
if [[ "$KEY_MODE" != 600 ]]; then
    printf ' Права закрытого ключа: %s\n' "$KEY_MODE"
    PERMISSIONS_OK=no
fi
check 'Нет записи для всех в каталоге сайта; права ключа 600' 'yes' "$PERMISSIONS_OK"

echo '[5] Контейнеризация'
DOCKER_STATE="$(systemctl is-active docker 2>/dev/null)" || :
check 'Служба docker активна' 'active' "$DOCKER_STATE"
DB_HEALTH="$(as_root docker inspect -f '{{.State.Health.Status}}' app-db-1 2>/dev/null)" || DB_HEALTH='недоступен'
check 'Контейнер PostgreSQL healthy' 'healthy' "$DB_HEALTH"

PORTS_SAFE=yes
if LISTENERS="$(ss -H -tln)"; then
    UNSAFE_LISTENERS="$(awk '$4 ~ /:(5000|5432)$/ && $4 !~ /^127\.0\.0\.1:(5000|5432)$/ {print $4}' <<< "$LISTENERS")"
    if [[ -n "$UNSAFE_LISTENERS" ]]; then
        printf ' Недопустимые адреса публикации:\n%s\n' "$UNSAFE_LISTENERS"
        PORTS_SAFE=no
    fi
else
    PORTS_SAFE=no
fi
check 'Порты 5000/5432 не открыты вне 127.0.0.1' 'yes' "$PORTS_SAFE"
ENV_MODE="$(as_root stat -c '%a' /home/devops/app/.env 2>/dev/null)" || ENV_MODE='недоступен'
check 'Права /home/devops/app/.env равны 600' '600' "$ENV_MODE"

printf 'Пройдено: %s, не пройдено: %s\n' "$PASS" "$FAIL"
if (( FAIL == 0 )); then exit 0; else exit 1; fi
