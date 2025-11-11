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
# Установить только определенные модули
./install.sh --modules="dns,nginx,php"

# Пропустить модули
./install.sh --skip="proxy-squid,vpn-wireguard"

# Режим отладки
./install.sh --debug

# Тихая установка с конфигом
./install.sh --config=myconfig.conf --quiet

# Проверка без изменений (dry run)
./install.sh --dry-run

# Форсированная переустановка
./install.sh --force
```

## Настройка PuTTY

```bash
"C:\Program Files\PuTTY\putty.exe" -load "connection_name" root@server_ip -pw server_password
```

## Системные требования

- **ОС**: Debian 11+ (Bullseye или новее)
- **RAM**: минимум 2GB (рекомендуется 4GB+)
- **Диск**: минимум 2GB свободного места
- **Права**: root доступ
- **Сеть**: статический IP, открытые порты 25, 80, 443, 587, 993, 995, 1194, 3128

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
- **VPN-сервер** (OpenVPN) для безопасного удалённого доступа

### Дополнительные сервисы (в разработке)
- **Git сервер** для управления репозиториями кода
- **Облачное хранилище** (NextCloud) для файлов и документов

### Безопасность
- **UFW Firewall** с настроенными правилами
- **SSL/TLS сертификаты** (Let's Encrypt или самоподписанные)
- **Fail2Ban** защита от брутфорса (опционально)

## Структура

```
server_script/
├── README.md
├── bootstrap.sh                    # Скрипт автозагрузки с GitHub
├── install.sh                      # Главный оркестратор
├── config/
│   └── main.conf                   # Основная конфигурация
├── utils/
│   ├── functions.sh                # Общие функции
│   ├── print.sh                    # Цветной вывод
│   └── logging.sh                  # Система логирования
└── modules/
    ├── 01-prerequisites.sh         # Проверка системы
    ├── 02-basic-software.sh        # Базовое ПО
    ├── 03-user-management.sh       # Создание пользователей
    ├── 04-certificates.sh          # Сертификаты и репозитории
    ├── 05-hostname.sh              # Настройка имени хоста
    ├── 06-firewall.sh              # Настройка UFW
    ├── 07-dns-server.sh            # DNS сервер BIND9
    ├── 08-web-server.sh            # Веб-сервер NGINX
    ├── 09-database.sh              # База данных PostgreSQL
    ├── 10-php-fpm.sh               # PHP-FPM и расширения
    ├── 11-mail-postfix.sh          # Почтовый сервер Postfix
    ├── 12-mail-opendkim.sh         # DKIM подписи и защита
    ├── 13-mail-dovecot.sh          # IMAP/POP3 сервер Dovecot
    ├── 14-webadmin-postfixadmin.sh # Веб-админка почты
    ├── 15-webmail-roundcube.sh     # Веб-почта Roundcube
    ├── 16-proxy-squid.sh           # HTTP/HTTPS прокси-сервер Squid
    ├── 17-vpn-wireguard.sh         # VPN сервер Wireguard
    ├── 18-git-gitea.sh             # Git сервер Gitea
    ├── 19-cloud-nextcloud.sh       # Облачный сервер NextCloud
    └── 99-system-check.sh          # Финальная проверка
```

## Конфигурация

### Основные параметры в `config/main.conf`:

```bash
# Основные настройки и учетная запись
DOMAIN="example.com"                # Ваш домен
SERVER_IP="192.168.1.10"            # IP адрес сервера
ADMIN_USER="webadmin"               # Пользователь (не root)
ADMIN_PASSWORD="SecurePassword123"  # Пароль администратора
ADMIN_EMAIL="admin@example.com"     # Email администратора
ADMIN_SSH_KEY=""                    # SSH ключ (рекомендуется)
DISABLE_ROOT_SSH=true               # Отключить root по SSH

# Прокси-сервер (Squid)
ENABLE_PROXY="true"
PROXY_USER="proxyuser"
HTTP_PROXY_PORT="3128"
PROXY_SUBDOMAIN="proxy"

# Единая БД для почтовой системы
MAIL_DB_NAME="${DOMAIN//./_}"      # murashkin_info
MAIL_DB_USER="$ADMIN_USER"         # webadmin
MAIL_DB_PASSWORD="$ADMIN_PASSWORD" # из конфига

# Отдельная БД для Roundcube
ROUNDCUBE_DB_NAME="roundcube"
ROUNDCUBE_DB_USER="roundcube"
ROUNDCUBE_DB_PASSWORD="$ADMIN_PASSWORD"

# Дополнительные почтовые ящики (создаются автоматически)
# Формат: "user1:password1,user2:password2,user3"
# Если пароль не указан - используется ADMIN_PASSWORD
ADDITIONAL_MAILBOXES="admin:$ADMIN_PASSWORD,example:77example7_P@ssword,info"

# VPN-сервер (OpenVPN)
ENABLE_VPN="true"
VPN_PORT="1194"
VPN_PROTOCOL="udp"
VPN_SUBNET="10.8.0.0"

# Безопасность
ENABLE_UFW=true                     # Включить firewall
ENABLE_FAIL2BAN=true                # Защита от брутфорса
SSL_PROVIDER="letsencrypt"          # letsencrypt или self-signed

# Модули
MODULES=""                          # Какие модули установить (пусто = все)
SKIP_MODULES=""                     # Какие модули пропустить
```

## Архитектура базы данных

Система использует **PostgreSQL** с раздельными базами данных для разных компонентов:

### Единая БД для почтовой системы

```
База: murashkin_info (из домена murashkin.info)
Пользователь: webadmin
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

**Важно:** Roundcube подключается к почтовому серверу через **IMAP/SMTP localhost**, а не напрямую к БД. Его собственная БД нужна только для хранения сессий и настроек веб-интерфейса.