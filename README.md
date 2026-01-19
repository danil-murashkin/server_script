# Развёртка универсального сервера

Автоматизированная система развёртывания полнофункционального сервера на базе Debian 11+. Включает DNS, веб-сервер, базу данных, почтовый сервер с DKIM/SPF/DMARC, веб-интерфейсы управления, прокси-сервер и VPN.

## Установка

### Одна команда для полной установки
```bash
curl -sSL https://raw.githubusercontent.com/danil-murashkin/server_script/main/bootstrap.sh | bash -s -- --install
```

### Ручная установка с настройкой
```bash
curl -sSL https://raw.githubusercontent.com/danil-murashkin/server_script/main/bootstrap.sh | bash && cd server_script

# Отредактируйте config/main.conf под ваши нужды
nano config/main.conf

# Запустите установку
./install.sh
```

## Параметры запуска

```bash
# Быстрая установка с параметрами (без интерактивного ввода)
./install.sh --domain=example.com --password=SecurePass123 --ip=1.2.3.4 --email=admin@example.com

# Автоматические значения по умолчанию (ip автоопределяется, email = admin@domain)
./install.sh --domain=example.com --password=SecurePass123 --ip="" --email=""

# Установить только определенные модули
./install.sh --modules="dns,nginx,php"

# Пропустить модули
./install.sh --skip="proxy-squid,vpn-wireguard"

# Режим отладки (DEBUG уровень логирования)
./install.sh --debug

# Фоновая установка (запуск в фоне с полным логированием)
./install.sh --background

# Проверка без изменений (dry run)
./install.sh --dry-run

# Форсированная переустановка (игнорировать ошибки)
./install.sh --force

# Использовать другой конфигурационный файл
./install.sh --config=myconfig.conf
```

### Фоновая установка

При использовании параметра `--background`:
- Процесс запускается в фоне через `nohup`
- Весь вывод сохраняется в логи
- Можно закрыть терминал - установка продолжится
- PID процесса сохраняется в `/tmp/installer_bg_running`

```bash
# Запуск в фоне
./install.sh --background

# Просмотр логов в реальном времени
tail -f /var/log/server-installer/console.log

# Или лог событий
tail -f /var/log/server-installer/install.log
```

## Логирование

Система создает два типа логов в директории `/var/log/server-installer/`:

1. **install.log** - структурированный лог событий с метками времени
   - Форматированные записи о ходе установки
   - Уровни: DEBUG, INFO, WARN, ERROR
   - Используется для анализа выполнения модулей

2. **console.log** - полный вывод консоли (stdout/stderr)
   - Дублирует весь вывод в консоль включая команды
   - Используется для отладки и полной трассировки

Управление логированием через `config/main.conf`:
```bash
LOG_DIR="/var/log/server-installer"  # Директория логов
LOG_FILE="install.log"                # Имя лога событий
CONSOLE_LOG_FILE="console.log"        # Имя лога консоли
ENABLE_LOG_FILE=true                  # Включить лог событий
ENABLE_CONSOLE_LOG=true               # Включить лог консоли
LOG_LEVEL="INFO"                      # Уровень детализации
```

## Настройка PuTTY

```bash
"C:\Program Files\PuTTY\putty.exe" -load "connection_name" root@server_ip -pw server_password
```

## Системные требования

- **ОС**: Debian 11+ (Bullseye или новее)
- **RAM**: минимум 2GB (рекомендуется 4GB+)
- **Диск**: минимум 20GB свободного места
- **Права**: root доступ
- **Сеть**: статический IP, открытые порты 22, 25, 80, 443, 587, 993, 995, 3128, 51820

## Что устанавливается

### Базовая инфраструктура
- **DNS сервер** (BIND9) с записями для всех сервисов
- **Веб-сервер** (NGINX) с поддержкой HTTP/2 и SSL
- **База данных** (PostgreSQL) для всех веб-приложений
- **PHP 8.2** с необходимыми расширениями и Composer

### Почтовая система
- **SMTP сервер** (Postfix) с виртуальными доменами
- **IMAP/POP3** (Dovecot) с поддержкой SSL/TLS
- **DKIM подписи** (OpenDKIM) для аутентификации
- **SPF и DMARC** записи для защиты от спама

### Веб-интерфейсы
- **PostfixAdmin** - управление почтовыми ящиками и доменами
- **Roundcube** - веб-почта с современным интерфейсом

### Сетевые сервисы
- **Прокси-сервер** (Squid) для HTTP/HTTPS туннелирования
- **VPN-сервер** (WireGuard) для безопасного удалённого доступа

### Дополнительные сервисы
- **Git сервер** (Gitea) для управления репозиториями кода
- **Облачное хранилище** (NextCloud) для файлов и документов

### Безопасность
- **UFW Firewall** с настроенными правилами
- **SSL/TLS сертификаты** (Let's Encrypt или самоподписанные)
- **Fail2Ban** защита от брутфорса

## Структура проекта

```
server_script/
├── README.md
├── bootstrap.sh                    # Скрипт автозагрузки с GitHub
├── install.sh                      # Главный оркестратор установки
├── config/
│   └── main.conf                   # Основная конфигурация
├── utils/
│   ├── functions.sh                # Общие функции
│   ├── print.sh                    # Цветной вывод в терминал
│   └── logging.sh                  # Система логирования
└── modules/
    ├── 01-prerequisites.sh         # Проверка системы
    ├── 02-basic-software.sh        # Базовое ПО
    ├── 03-user-management.sh       # Создание пользователей
    ├── 04-certificates.sh          # SSL/TLS сертификаты
    ├── 05-hostname.sh              # Настройка имени хоста
    ├── 06-firewall.sh              # Настройка UFW
    ├── 07-dns-server.sh            # DNS сервер BIND9
    ├── 08-web-server.sh            # Веб-сервер NGINX
    ├── 09-database.sh              # База данных PostgreSQL
    ├── 10-php-fpm.sh               # PHP-FPM и расширения
    ├── 11-mail-postfix.sh          # Почтовый сервер Postfix
    ├── 12-mail-opendkim.sh         # DKIM подписи и защита
    ├── 13-mail-dovecot.sh          # IMAP/POP3 сервер Dovecot
    ├── 14-webadmin-postfixadmin.sh # Веб-админка почты PostfixAdmin
    ├── 15-webmail-roundcube.sh     # Веб-почта Roundcube
    ├── 16-proxy-squid.sh           # HTTP/HTTPS прокси-сервер Squid
    ├── 17-vpn-wireguard.sh         # VPN сервер WireGuard
    ├── 18-git-gitea.sh             # Git сервер Gitea
    ├── 19-cloud-nextcloud.sh       # Облачный сервер NextCloud
    └── 99-system-check.sh          # Финальная проверка системы
```

## Конфигурация

### Основные параметры в `config/main.conf`:

#### Базовые настройки
```bash
# Основные настройки и учетная запись
DOMAIN="example.com"                # Ваш домен
SERVER_IP="192.168.1.10"            # IP адрес сервера
ADMIN_USER="webadmin"               # Пользователь (не root)
ADMIN_PASSWORD="SecurePassword123"  # Пароль администратора
ADMIN_EMAIL="admin@example.com"     # Email администратора
ADMIN_SSH_KEY=""                    # SSH ключ (рекомендуется)
DISABLE_ROOT_SSH=true               # Отключить root по SSH
```

#### Отладка и логирование
```bash
DEBUG_MODE=false                    # Режим отладки
LOG_DIR="/var/log/server-installer" # Директория логов
LOG_FILE="install.log"              # Лог событий
CONSOLE_LOG_FILE="console.log"      # Лог консоли
ENABLE_LOG_FILE=true                # Включить лог событий
ENABLE_CONSOLE_LOG=true             # Включить лог консоли
LOG_LEVEL="INFO"                    # DEBUG, INFO, WARN, ERROR
```

#### Безопасность
```bash
ENABLE_UFW=true                     # Включить firewall
ENABLE_FAIL2BAN=true                # Защита от брутфорса
SSL_PROVIDER="letsencrypt"          # letsencrypt или self-signed
ENABLE_SSL=true                     # Включить SSL/TLS
SSL_USE_STAGING=false               # Тестовые сертификаты
```

#### Прокси-сервер (Squid)
```bash
ENABLE_PROXY="true"
PROXY_USER="proxyuser"
PROXY_PASSWORD=""                   # Пустое = использовать ADMIN_PASSWORD
HTTP_PROXY_PORT="3128"
PROXY_SUBDOMAIN="proxy"             # proxy.$DOMAIN
PROXY_CACHE_SIZE="100"              # MB
```

#### VPN-сервер (WireGuard)
```bash
ENABLE_VPN="true"
VPN_PORT="51820"
VPN_SUBNET="10.8.0.0"
VPN_CIDR="24"
VPN_DNS="8.8.8.8, 8.8.4.4"
VPN_SUBDOMAIN="vpn"                 # vpn.$DOMAIN
VPN_USER="${ADMIN_USER:-admin}"
VPN_REDIRECT_GATEWAY="true"         # Full tunnel
VPN_CLIENT_TO_CLIENT="false"        # Изоляция клиентов
```

#### Git-сервер (Gitea)
```bash
ENABLE_GITEA=true
GITEA_DOMAIN="git.$DOMAIN"
GITEA_PORT=3000                     # Внутренний порт
GITEA_SSH_PORT=2222                 # SSH порт для Git
GITEA_VERSION="1.21.11"
GITEA_ADMIN_USER="gitadmin"
GITEA_DISABLE_REGISTRATION=true     # Только админ создает пользователей
```

#### Облачное хранилище (NextCloud)
```bash
ENABLE_NEXTCLOUD="true"
NEXTCLOUD_VERSION="32.0.1"
NEXTCLOUD_SUBDOMAIN="cloud"         # cloud.$DOMAIN
NEXTCLOUD_DATA_DIR="/var/www/nextcloud-data"
NEXTCLOUD_ADMIN_USER="admin"
```

#### Модули
```bash
MODULES=""                          # Какие модули установить (пусто = все)
SKIP_MODULES=""                     # Какие модули пропустить
```

## Архитектура базы данных

Система использует **PostgreSQL** с раздельными базами данных для разных компонентов:

### Единая БД для почтовой системы

```
База: ${DOMAIN//./_}  (например: murashkin_info из murashkin.info)
Пользователь: webadmin (ADMIN_USER)
Пароль: ADMIN_PASSWORD из main.conf

Используется компонентами:
├── Postfix (SMTP)          → таблицы: domain, mailbox, alias
├── Dovecot (IMAP/POP3)     → таблицы: mailbox
└── PostfixAdmin (управление) → все таблицы PostfixAdmin
```

### Отдельная БД для Roundcube

```
База: roundcube
Пользователь: roundcube
Пароль: ADMIN_PASSWORD из main.conf

Используется только для:
└── Roundcube (веб-почта) → таблицы: session, users, cache, contacts
```

### Отдельная БД для Gitea

```
База: gitea
Пользователь: gitea
Пароль: ADMIN_PASSWORD из main.conf

Используется для:
└── Gitea (Git-сервер) → все таблицы Gitea
```

### Отдельная БД для NextCloud

```
База: nextcloud
Пользователь: nextcloud
Пароль: ADMIN_PASSWORD из main.conf

Используется для:
└── NextCloud (облако) → все таблицы NextCloud
```

**Важно:** Roundcube подключается к почтовому серверу через **IMAP/SMTP localhost**, а не напрямую к БД. Его собственная БД нужна только для хранения сессий и настроек веб-интерфейса.

## Дополнительные почтовые ящики

Автоматическое создание почтовых ящиков при установке:

```bash
# В config/main.conf
ADDITIONAL_MAILBOXES="admin:SecurePass123,info,support:AnotherPass456"
```

Формат: `user1:password1,user2,user3:password3`
- Если пароль не указан - используется `ADMIN_PASSWORD`
- Ящики создаются для домена `DOMAIN`

## Доступ к сервисам

После установки сервисы доступны по следующим адресам:

| Сервис | URL | Порт | Описание |
|--------|-----|------|----------|
| Веб-сервер | `https://example.com` | 443 | Главный сайт |
| PostfixAdmin | `https://mailadmin.example.com` | 443 | Управление почтой |
| Roundcube | `https://webmail.example.com` | 443 | Веб-почта |
| Gitea | `https://git.example.com` | 443 | Git-репозитории |
| NextCloud | `https://cloud.example.com` | 443 | Облачное хранилище |
| Squid Proxy | `proxy.example.com` | 3128 | HTTP/HTTPS прокси |
| WireGuard VPN | `vpn.example.com` | 51820 | VPN-сервер |
| SSH | `example.com` | 22 | Удаленный доступ |
| SMTP | `mail.example.com` | 25, 587 | Отправка почты |
| IMAP | `mail.example.com` | 993 | Получение почты (SSL) |
| POP3 | `mail.example.com` | 995 | Получение почты (SSL) |

## Устранение неполадок

### Просмотр логов
```bash
# Лог событий установки
tail -f /var/log/server-installer/install.log

# Полный вывод консоли
tail -f /var/log/server-installer/console.log

# Логи конкретного сервиса
journalctl -u nginx -f
journalctl -u postfix -f
journalctl -u postgresql -f
```

### Проверка статуса сервисов
```bash
systemctl status nginx
systemctl status postgresql
systemctl status postfix
systemctl status dovecot
```

### Переустановка модуля
```bash
# Установить только один модуль
./install.sh --modules="08-web-server"

# Или с форсированием
./install.sh --modules="08-web-server" --force
```

### Проверка портов
```bash
ss -tlnp | grep -E ':(80|443|25|587|993|995|3128|51820)'
```

## Безопасность

### Рекомендации после установки

1. **Измените все пароли** из `main.conf` на продакшене
2. **Настройте SSH-ключи** вместо паролей
3. **Включите двухфакторную аутентификацию** где возможно
4. **Регулярно обновляйте** систему и сервисы
5. **Настройте резервное копирование** баз данных
6. **Проверьте логи** Fail2Ban и UFW

### Обновление сертификатов Let's Encrypt

Сертификаты обновляются автоматически через cron. Проверка:
```bash
certbot renew --dry-run
```

## Лицензия

MIT License

## Автор

Danil Murashkin

## Поддержка

Если возникли проблемы, создайте issue в репозитории проекта на GitHub.