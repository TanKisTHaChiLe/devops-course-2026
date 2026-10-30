# Конфигурация виртуальной машины devops-vm

## 1. Параметры машины

- Хост: macOS, Apple M2; VirtualBox 7.2.22.
- Гостевая ОС: Ubuntu Server 24.04.5 LTS, ARM64.
- Память: 2048 МБ; процессоры: 2; виртуальный диск: 25 ГБ, динамический.
- Разметка LVM: корневой том около 11 ГБ; оставшаяся часть группы не распределена.

## 2. Сетевые интерфейсы

| Интерфейс | Тип | Адрес | Назначение |
|---|---|---|---|
| enp0s8 | NAT | 10.0.2.15/24 | Доступ к интернету и пакетам |
| enp0s9 | Host-only Network, HostNetwork | 192.168.56.2/24 | Прямой доступ с Mac к сайту |

Адреса получены автоматически. После изменения сети проверить `ip -brief address`.
В `/etc/hosts` на Mac добавлена запись:

```text
192.168.56.2 devops.local
```

На сервере:

```bash
sudo hostnamectl set-hostname devops-vm
```

Строка `/etc/hosts` сервера:

```text
127.0.1.1 devops-vm.devops.local devops-vm
```

Проверка: `hostname -f` выводит `devops-vm.devops.local`.

## 3. Правило проброса портов

Правило `ssh`, TCP: `127.0.0.1:2222` на Mac -> порт `2222` гостевой системы.
В исходном снимке `01-clean-install` порт гостя равен `22`; изменить его после смены порта SSH.
HTTP/HTTPS доступны через Host-only без проброса.

## 4. Учётные записи

- `student`: пользователь установки, имеет sudo; после hardening вход по SSH запрещён директивой AllowUsers.
- `devops`: пользователь администрирования и доставки сайта, группы `devops`, `sudo`, `users`.
- `www-data`: непривилегированные рабочие процессы Nginx; не владелец файлов сайта.

Создание администратора из консоли или начальной SSH-сессии student:

```bash
sudo adduser devops
sudo usermod -aG sudo devops
```

На Mac используется отдельный ключ `~/.ssh/devops_vm`, его открытая часть установлена в
`/home/devops/.ssh/authorized_keys`. Права каталога `.ssh` - 700, файла `authorized_keys` - 600.
Закрытый ключ и пароли в репозитории не хранятся.
В `~/.ssh/config` на Mac:

```sshconfig
Host devops
    HostName 127.0.0.1
    Port 2222
    User devops
    IdentityFile ~/.ssh/devops_vm
    IdentitiesOnly yes
```

## 5. Служба SSH

Исходный `/etc/ssh/sshd_config` сохранён в `/etc/ssh/sshd_config.backup`.
Настройки записаны в `/etc/ssh/sshd_config.d/99-hardening.conf`:

```text
Port 2222
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
AllowUsers devops
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
```

Конфликтующая директива `PasswordAuthentication yes` в `50-cloud-init.conf` закомментирована.
Сначала убедиться во входе devops по ключу; сохранить текущую SSH-сессию открытой.

```bash
sudo sshd -t
sudo sshd -T
sudo systemctl disable --now ssh.socket
sudo systemctl enable --now ssh.service
sudo systemctl restart ssh
sudo ss -tlnp | grep sshd
```

После смены порта изменить проброс, проверить новое соединение `ssh devops` в отдельном терминале.

## 6. Правила межсетевого экрана

UFW активен. Политики: deny incoming, allow outgoing.
TCP 2222 - LIMIT; TCP 80 и 443 - ALLOW; правила применяются также к IPv6.
Журналирование: medium. Восстановление на чистой конфигурации:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw limit 2222/tcp comment 'SSH rate-limited'
sudo ufw allow 80/tcp comment 'HTTP'
sudo ufw allow 443/tcp comment 'HTTPS'
sudo ufw enable
sudo ufw logging medium
sudo ufw status verbose
```

Правило SSH обязательно добавляется до включения UFW. Проверить новое соединение отдельно.

## 7. Снимки состояния

| Имя | Момент создания |
|---|---|
| 01-clean-install | После установки и обновления Ubuntu |
| 02-keys-configured | После создания devops и проверки входа по ключу |
| 03-ssh-hardened | После усиления защиты SSH, до настройки UFW |
| 04-nginx-https | После настройки Nginx, TLS и перенаправления; до доставки страниц rsync |

Снимки 02-04 созданы на выключенной машине. Попытка live snapshot была отменена из-за
затянувшегося сохранения; впоследствии используется штатное выключение перед снимком.

## 8. Веб-сервер

Пакеты: `nginx`, `rsync`, `openssl`.

```bash
sudo apt update
sudo apt install -y nginx rsync openssl
sudo mkdir -p /var/www/devops-site
sudo chown devops:devops /var/www/devops-site
sudo chmod 755 /var/www/devops-site
```

Каталог ресурса: `/var/www/devops-site`, владелец `devops:devops`.
Права каталогов - 755, файлов - 644. Главный процесс Nginx работает от root,
рабочие - от www-data: они читают ресурс, но не могут изменять его.

Самоподписанный сертификат: `/etc/ssl/certs/devops.crt`, root:root, права 644.
Закрытый ключ: `/etc/ssl/private/devops.key`, root:root, права 600; его читает главный процесс Nginx.
Ключ не копируется с сервера и не добавляется в Git.

Формирование нового сертификата на восстановленной машине (не перезаписывать существующий без необходимости):

```bash
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/ssl/private/devops.key \
  -out /etc/ssl/certs/devops.crt \
  -subj '/CN=devops.local' \
  -addext 'subjectAltName=DNS:devops.local'
sudo chmod 600 /etc/ssl/private/devops.key
sudo chmod 644 /etc/ssl/certs/devops.crt
```

Срок выданного сертификата: 30.10.2026 21:28:02 UTC - 30.10.2027 21:28:02 UTC (365 дней).
SAN: DNS:devops.local. После перевыпуска заменить доверенную открытую копию через проверенное SSH-соединение.

Конфигурация `/etc/nginx/sites-available/devops-site`:

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name devops.local;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name devops.local;
    ssl_certificate /etc/ssl/certs/devops.crt;
    ssl_certificate_key /etc/ssl/private/devops.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    root /var/www/devops-site;
    index index.html;
    location / {
        try_files $uri $uri/ =404;
    }
    error_page 404 /404.html;
    access_log /var/log/nginx/devops-site.access.log;
    error_log /var/log/nginx/devops-site.error.log;
}
```

Активация на новой установке:

```bash
sudo ln -s /etc/nginx/sites-available/devops-site /etc/nginx/sites-enabled/devops-site
sudo rm /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
```

Удаляется только ссылка стандартного сайта. HSTS не добавляется для учебного самоподписанного сертификата.
Изменения применяются только после `nginx -t`, через reload.

Доставка выполняется на Mac из репозитория `devops-course-2026`:

```bash
scripts/deploy.sh --dry-run
scripts/deploy.sh
```

Скрипт использует один SSH-сеанс rsync, проверяет чистоту Git и наличие index.html,
устанавливает права 755/644 и проверяет HTTPS по открытому сертификату `certs/devops.crt`.
Для rsync 2.6.9 в macOS используется `--chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r`.
Проверка curl использует IPv4 (`-4`), сохраняя проверку имени и доверия TLS.

Аудит запускается внутри Ubuntu из копии `scripts/audit.sh`:

```bash
bash scripts/audit.sh
echo $?
```

Порог проверки сертификата по умолчанию - 2592000 секунд (30 дней).
Для отрицательного теста: `CERT_MIN_SECONDS=34560000 bash scripts/audit.sh` (400 дней).
Вторая отрицательная проверка: временно изменить права index.html на 666, запустить аудит,
затем обязательно вернуть 644 и повторить аудит. Ожидаемые коды: 0, 1, 1, 0.

### Проверки аудита для отчёта (задание 7)

Все следующие команды выполняются в Ubuntu. Копия скрипта размещена в
`/home/devops/scripts/audit.sh`. Код возврата выводится сразу после запуска.

Исправная конфигурация: все 10 проверок пройдены, ожидается код 0.

```bash
bash ~/scripts/audit.sh
echo $?
```

Проверка в): требование остаточного срока 400 дней превышает срок выданного
сертификата. Ожидается FAIL только у проверки срока сертификата и код 1.
Переменная применяется только к одному запуску; сертификат не изменяется.

```bash
CERT_MIN_SECONDS=34560000 bash ~/scripts/audit.sh
echo $?
```

Проверка г): временно разрешена запись в index.html всем пользователям.
Ожидается FAIL проверки прав и код 1.

```bash
chmod 666 /var/www/devops-site/index.html
bash ~/scripts/audit.sh
echo $?
```

После фиксации результата обязательно восстановить права и повторить аудит:

```bash
chmod 644 /var/www/devops-site/index.html
bash ~/scripts/audit.sh
echo $?
```

Ожидается код 0. В отчёт включаются текст раздела 8 и результаты трёх
сценариев: исправная конфигурация, нарушение условия в), нарушение условия г).

## 9. Контейнеризация

Docker Engine Community установлен внутри Ubuntu ARM64 из официального APT-репозитория
`https://download.docker.com/linux/ubuntu`, ветка `noble stable`, с ключом
`/etc/apt/keyrings/docker.asc`. Источник описан в `/etc/apt/sources.list.d/docker.sources`.
Пакеты: `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`,
`docker-compose-plugin`. Пакет Ubuntu `docker.io` не используется.
Зафиксированные версии: Docker Engine 29.9.2, Compose v5.6.1.

```bash
sudo apt update
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod 644 /etc/apt/keyrings/docker.asc
sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker devops
```

После добавления в группу открыть новое SSH-соединение. Пользователь группы docker -
`devops`, уже имеющий sudo. Доступ к Docker фактически даёт полномочия root на Ubuntu.

Исходники хранятся в `app/` репозитория; рабочий проект на сервере - `/home/devops/app`.
Образ `devops-app:1.0` основан на `python:3.12-slim`, приложение запускается от `app`
(UID 999), а не root. Зависимости устанавливаются до копирования app.py для использования кэша.

Доставка с Mac (сначала проверить план):

```bash
rsync -avz --delete --exclude=.env --dry-run app/ devops:app/
rsync -avz --delete --exclude=.env app/ devops:app/
```

Настройки находятся только на сервере в `/home/devops/app/.env`, владелец `devops:devops`,
права 600. Переменные: `POSTGRES_DB=app`, `POSTGRES_USER=app`, `DB_HOST=db` и случайный
`POSTGRES_PASSWORD`. В Git хранится лишь `.env.example` с заглушкой. `.env` исключён
из Git, контекста Docker и rsync. При первом развёртывании сгенерировать пароль на сервере:

```bash
cd ~/app
# Только если .env ещё не существует; не менять пароль существующей базы этим способом.
if [ ! -e .env ]; then
    (umask 077; cp .env.example .env)
    chmod 600 .env
    sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 16)/" .env
fi
docker compose up -d --build --wait
```

Compose-файл: `app/docker-compose.yml`. Проект `app` содержит сервисы `app` и `db`,
контейнеры `app-app-1` и `app-db-1`. База использует `postgres:16-alpine` и healthcheck
`pg_isready`; приложение стартует после `service_healthy`.
Общая bridge-сеть - `app_backend`: встроенный DNS разрешает имя сервиса `db`.

Публикация приложения: `127.0.0.1:5000:5000`. PostgreSQL не публикует порт 5432
на Ubuntu. Запись `5432/tcp` в docker compose ps обозначает внутренний порт, а не публикацию.
Именованный том `app_db_data` смонтирован в `/var/lib/postgresql/data` контейнера db.
`docker compose down` сохраняет данные; `docker compose down -v` удаляет том и базу.
Последняя команда использовалась только для учебного опыта со сбросом счётчика.

В HTTPS-блок `/etc/nginx/sites-available/devops-site` добавлено:

```nginx
location /app/ {
    proxy_pass http://127.0.0.1:5000/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

Статический `location /` сохранён. Применение: `sudo nginx -t && sudo systemctl reload nginx`.
Префикс `/app/` заменяется на `/` перед передачей в контейнер; `/app/health` становится `/health`.
Проверки с Mac используют `curl -4 --cacert certs/devops.crt` для URL
`https://devops.local/app/`, `https://devops.local/app/health` и `https://devops.local/`.

При остановленном app Nginx возвращает 502, в журнале
`/var/log/nginx/devops-site.error.log` появляется `connect() failed (111: Connection refused)`.
Восстановление: `cd ~/app && docker compose start app`.
Тестовый контейнер `exposed` с публикацией 5001 был остановлен и автоматически удалён.

Раздел `[5] Контейнеризация` в `scripts/audit.sh` проверяет активность Docker, healthy базы,
отсутствие публикации 5000/5432 вне 127.0.0.1 и права .env 600.
Запуск внутри Ubuntu: `bash ~/scripts/audit.sh; echo $?`.
После добавления проверок ожидается 14 успешных проверок и код 0.
Для отрицательной проверки в) временно заменить публикацию в серверном Compose-файле
на `5000:5000`, пересоздать app и запустить аудит: ожидается код 1.
Сразу вернуть `127.0.0.1:5000:5000`, пересоздать app и повторить аудит: ожидается код 0.
