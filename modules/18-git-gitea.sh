#!/bin/bash
# modules/18-git-gitea.sh - Установка и настройка Git-сервера Gitea
# Часть Server Deployment Module System

# --- Загрузка вспомогательных утилит ---
[[ -z "${UTIL_PRINT_LOADED}" ]] && source ./utils/print.sh 2>/dev/null
[[ -z "${UTIL_LOGGING_LOADED}" ]] && source ./utils/logging.sh 2>/dev/null
[[ -z "${UTIL_FUNCTIONS_LOADED}" ]] && source ./utils/functions.sh 2>/dev/null

# --- Проверка прав root ---
ensure_root

# --- Загружаем конфиг ---
load_config || {
    print_error "Не удалось загрузить конфигурацию"
    log_error "Failed to load configuration"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
}

# --- Проверка включения модуля ---
if [[ "${ENABLE_GITEA:-false}" != "true" ]]; then
    print_warning "Gitea отключен в конфигурации (ENABLE_GITEA=false)"
    log_info "Gitea installation skipped (ENABLE_GITEA=false)"
    exit 0
fi

# --- Проверка переменных ---
print_step "Проверка конфигурации Git-сервера"

GITEA_VERSION="${GITEA_VERSION:-1.21.11}"
GITEA_USER="${GITEA_USER:-git}"
GITEA_PORT="${GITEA_PORT:-3000}"
GITEA_SSH_PORT="${GITEA_SSH_PORT:-2222}"
GITEA_DOMAIN="${GITEA_DOMAIN:-git.$DOMAIN}"
GITEA_ROOT_URL="${GITEA_ROOT_URL:-https://$GITEA_DOMAIN}"
GITEA_DB_NAME="${GITEA_DB_NAME:-gitea}"
GITEA_DB_USER="${GITEA_DB_USER:-gitea}"
GITEA_DB_PASSWORD="${GITEA_DB_PASSWORD:-$ADMIN_PASSWORD}"
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-gitadmin}"
GITEA_ADMIN_PASSWORD="${GITEA_ADMIN_PASSWORD:-$ADMIN_PASSWORD}"
GITEA_ADMIN_EMAIL="${GITEA_ADMIN_EMAIL:-$ADMIN_EMAIL}"
GITEA_DISABLE_REGISTRATION="${GITEA_DISABLE_REGISTRATION:-true}"
GITEA_REQUIRE_SIGNIN="${GITEA_REQUIRE_SIGNIN:-false}"

log_info "Git URL: $GITEA_ROOT_URL"
log_info "Версия: $GITEA_VERSION"
log_info "HTTP порт: $GITEA_PORT, SSH порт: $GITEA_SSH_PORT"

# --- Проверка ОС ---
ensure_debian || {
    print_error "Поддерживается только Debian 11+"
    log_error "Unsupported OS"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
}

# --- Проверка зависимостей ---
require_command "psql" "PostgreSQL (модуль 09)"
require_command "nginx" "NGINX (модуль 08)"

if ! sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw postgres; then
    print_error "PostgreSQL не работает"
    log_error "PostgreSQL not running"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# --- Создание системного пользователя ---
print_step "Создание системного пользователя: $GITEA_USER"
if id "$GITEA_USER" &>/dev/null; then
    print_info "Пользователь $GITEA_USER уже существует"
    log_info "User $GITEA_USER exists"
else
    if [[ "$DRY_RUN" == "true" ]]; then
        print_warn "(DRY RUN) adduser --system --group $GITEA_USER"
    else
        adduser --system --group --disabled-password --shell /bin/bash --home /home/$GITEA_USER $GITEA_USER || {
            print_error "Не удалось создать пользователя"
            log_error "Failed to create user"
            [[ "$FORCE_MODE" != "true" ]] && exit 1
        }
        print_success "Пользователь создан"
        log_success "User created"
    fi
fi

# --- Создание директорий ---
print_step "Создание директорий Gitea"
GITEA_DIRS=(
    "/var/lib/gitea"
    "/var/lib/gitea/custom"
    "/var/lib/gitea/data"
    "/var/lib/gitea/log"
    "/etc/gitea"
)

for dir in "${GITEA_DIRS[@]}"; do
    if [[ "$DRY_RUN" == "true" ]]; then
        print_warn "(DRY RUN) mkdir -p $dir"
    else
        mkdir -p "$dir" || {
            print_error "Не удалось создать: $dir"
            log_error "Failed to create: $dir"
            [[ "$FORCE_MODE" != "true" ]] && exit 1
        }
    fi
done

if [[ "$DRY_RUN" != "true" ]]; then
    chown -R $GITEA_USER:$GITEA_USER /var/lib/gitea
    chmod -R 750 /var/lib/gitea
    chown -R $GITEA_USER:$GITEA_USER /etc/gitea
    chmod 750 /etc/gitea
    print_success "Директории настроены"
    log_success "Directories configured"
fi

# --- Определение архитектуры ---
print_step "Определение архитектуры"
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  GITEA_ARCH="linux-amd64" ;;
    aarch64) GITEA_ARCH="linux-arm64" ;;
    armv7l)  GITEA_ARCH="linux-arm-7" ;;
    *)
        print_error "Неподдерживаемая архитектура: $ARCH"
        log_error "Unsupported arch: $ARCH"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
        ;;
esac
log_info "Архитектура: $ARCH → $GITEA_ARCH"

# --- Скачивание Gitea ---
print_step "Скачивание Gitea $GITEA_VERSION"
GITEA_URL="https://dl.gitea.com/gitea/$GITEA_VERSION/gitea-$GITEA_VERSION-$GITEA_ARCH"
GITEA_BINARY="/usr/local/bin/gitea"

if [[ "$DRY_RUN" == "true" ]]; then
    print_warn "(DRY RUN) curl -sL $GITEA_URL -o $GITEA_BINARY"
else
    # Проверяем, установлен ли уже Gitea
    if [[ -f "$GITEA_BINARY" ]]; then
        CURRENT_VERSION=$($GITEA_BINARY --version 2>/dev/null | head -n1 || echo "unknown")
        if [[ "$CURRENT_VERSION" =~ "$GITEA_VERSION" ]]; then
            print_info "Gitea $GITEA_VERSION уже установлен"
            log_info "Gitea already installed: $CURRENT_VERSION"
        else
            print_info "Обновление Gitea: $CURRENT_VERSION → $GITEA_VERSION"
            log_info "Updating Gitea: $CURRENT_VERSION → $GITEA_VERSION"
            rm -f "$GITEA_BINARY"
        fi
    fi
    
    # Скачиваем только если файла нет
    if [[ ! -f "$GITEA_BINARY" ]]; then
        log_info "Downloading from: $GITEA_URL"
        
        if curl -fsSL "$GITEA_URL" -o "$GITEA_BINARY" 2>/dev/null; then
            chmod +x "$GITEA_BINARY"
            print_success "Gitea установлен"
            log_success "Gitea binary downloaded"
            INSTALLED_VERSION=$($GITEA_BINARY --version | head -n1)
            log_info "Version: $INSTALLED_VERSION"
        else
            print_error "Не удалось скачать Gitea"
            print_info "URL: $GITEA_URL"
            print_info "Проверьте интернет-соединение и доступность dl.gitea.com"
            log_error "Download failed from $GITEA_URL"
            [[ "$FORCE_MODE" != "true" ]] && exit 1
        fi
    fi
fi

# --- Создание пользователя БД ---
print_step "Создание пользователя БД: $GITEA_DB_USER"
if [[ "$DRY_RUN" == "true" ]]; then
    print_warn "(DRY RUN) Создание пользователя БД"
else
    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$GITEA_DB_USER'" | grep -q 1; then
        print_info "Пользователь БД существует"
        log_info "DB user exists"
    else
        sudo -u postgres psql -c "CREATE USER $GITEA_DB_USER WITH PASSWORD '$GITEA_DB_PASSWORD';" || {
            print_error "Не удалось создать пользователя БД"
            log_error "DB user creation failed"
            [[ "$FORCE_MODE" != "true" ]] && exit 1
        }
        print_success "Пользователь БД создан"
        log_success "DB user created"
    fi
fi

# --- Создание базы данных ---
print_step "Создание базы данных: $GITEA_DB_NAME"
if [[ "$DRY_RUN" == "true" ]]; then
    print_warn "(DRY RUN) Создание БД"
else
    if sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw "$GITEA_DB_NAME"; then
        print_info "База данных существует"
        log_info "Database exists"
    else
        sudo -u postgres psql -c "CREATE DATABASE $GITEA_DB_NAME OWNER $GITEA_DB_USER;" || {
            print_error "Не удалось создать БД"
            log_error "DB creation failed"
            [[ "$FORCE_MODE" != "true" ]] && exit 1
        }
        print_success "База данных создана"
        log_success "Database created"
    fi
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $GITEA_DB_NAME TO $GITEA_DB_USER;"
    log_success "DB privileges granted"
fi

# --- Создание конфигурации ---
print_step "Создание конфигурации: /etc/gitea/app.ini"
if [[ "$DRY_RUN" == "true" ]]; then
    print_warn "(DRY RUN) Создание app.ini"
else
    SECRET_KEY=$(gitea generate secret SECRET_KEY 2>/dev/null || openssl rand -base64 32)
    INTERNAL_TOKEN=$(gitea generate secret INTERNAL_TOKEN 2>/dev/null || openssl rand -base64 86)
    JWT_SECRET=$(gitea generate secret JWT_SECRET 2>/dev/null || openssl rand -base64 43)
    
    cat > /etc/gitea/app.ini <<EOF
APP_NAME = Gitea: Git сервер
RUN_USER = $GITEA_USER
RUN_MODE = prod

[server]
PROTOCOL = http
DOMAIN = $GITEA_DOMAIN
ROOT_URL = $GITEA_ROOT_URL
HTTP_ADDR = 127.0.0.1
HTTP_PORT = $GITEA_PORT
DISABLE_SSH = false
SSH_DOMAIN = $GITEA_DOMAIN
SSH_PORT = $GITEA_SSH_PORT
SSH_LISTEN_PORT = $GITEA_SSH_PORT
START_SSH_SERVER = true
OFFLINE_MODE = false
LFS_START_SERVER = true

[database]
DB_TYPE = postgres
HOST = 127.0.0.1:5432
NAME = $GITEA_DB_NAME
USER = $GITEA_DB_USER
PASSWD = $GITEA_DB_PASSWORD
SCHEMA = 
SSL_MODE = disable
LOG_SQL = false

[repository]
ROOT = /var/lib/gitea/data/gitea-repositories
DEFAULT_BRANCH = main
DEFAULT_PRIVATE = last
ENABLE_PUSH_CREATE_USER = true
ENABLE_PUSH_CREATE_ORG = true

[security]
INSTALL_LOCK = true
SECRET_KEY = $SECRET_KEY
INTERNAL_TOKEN = $INTERNAL_TOKEN
PASSWORD_HASH_ALGO = pbkdf2

[service]
DISABLE_REGISTRATION = $GITEA_DISABLE_REGISTRATION
REQUIRE_SIGNIN_VIEW = $GITEA_REQUIRE_SIGNIN
REGISTER_EMAIL_CONFIRM = false
ENABLE_NOTIFY_MAIL = false
ALLOW_ONLY_EXTERNAL_REGISTRATION = false
ENABLE_CAPTCHA = false
DEFAULT_KEEP_EMAIL_PRIVATE = true
DEFAULT_ALLOW_CREATE_ORGANIZATION = true
DEFAULT_ENABLE_TIMETRACKING = true
NO_REPLY_ADDRESS = noreply.$DOMAIN

[mailer]
ENABLED = false

[session]
PROVIDER = file
PROVIDER_CONFIG = /var/lib/gitea/data/sessions

[picture]
AVATAR_UPLOAD_PATH = /var/lib/gitea/data/avatars
REPOSITORY_AVATAR_UPLOAD_PATH = /var/lib/gitea/data/repo-avatars
DISABLE_GRAVATAR = true
ENABLE_FEDERATED_AVATAR = false

[attachment]
ENABLED = true
PATH = /var/lib/gitea/data/attachments
MAX_SIZE = 100
MAX_FILES = 10

[log]
MODE = console, file
LEVEL = Info
ROOT_PATH = /var/lib/gitea/log

[log.console]
LEVEL = Warn

[log.file]
LEVEL = Info
LOG_ROTATE = true
MAX_DAYS = 7

[oauth2]
JWT_SECRET = $JWT_SECRET

[other]
SHOW_FOOTER_VERSION = false
SHOW_FOOTER_TEMPLATE_LOAD_TIME = false
EOF

    chown $GITEA_USER:$GITEA_USER /etc/gitea/app.ini
    chmod 600 /etc/gitea/app.ini
    print_success "Конфигурация создана"
    log_success "Configuration created"
fi

# --- Создание systemd сервиса ---
print_step "Создание systemd сервиса"
if [[ "$DRY_RUN" == "true" ]]; then
    print_warn "(DRY RUN) Создание gitea.service"
else
    # Сначала проверим, запускается ли Gitea вообще
    print_step "Тестовый запуск Gitea"
    if ! sudo -u $GITEA_USER /usr/local/bin/gitea --version >/dev/null 2>&1; then
        print_error "Не удалось запустить Gitea бинарник"
        log_error "Gitea binary check failed"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
    print_success "Gitea бинарник работает"
    
    cat > /etc/systemd/system/gitea.service <<EOF
[Unit]
Description=Gitea (Git with a cup of tea)
After=syslog.target
After=network.target
After=postgresql.service

[Service]
Type=simple
User=$GITEA_USER
Group=$GITEA_USER
WorkingDirectory=/var/lib/gitea
ExecStart=/usr/local/bin/gitea web --config /etc/gitea/app.ini
Restart=always
Environment=USER=$GITEA_USER HOME=/home/$GITEA_USER GITEA_WORK_DIR=/var/lib/gitea

[Install]
WantedBy=multi-user.target
EOF

    print_success "Сервис создан"
    log_success "Service file created"
    
    systemctl daemon-reload
    systemctl enable gitea
    systemctl start gitea
    
    sleep 3
    
    if systemctl is-active --quiet gitea; then
        print_success "Gitea запущен"
        log_success "Gitea started"
    else
        print_error "Не удалось запустить Gitea"
        log_error "Failed to start Gitea"
        systemctl status gitea --no-pager
        print_info ""
        print_info "Логи Gitea:"
        journalctl -u gitea -n 50 --no-pager
        print_info ""
        print_info "Последние строки лога:"
        tail -20 /var/lib/gitea/log/gitea.log 2>/dev/null || echo "Лог-файл не найден"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
fi

# --- Создание администратора ---
print_step "Создание администратора: $GITEA_ADMIN_USER"
if [[ "$DRY_RUN" == "true" ]]; then
    print_warn "(DRY RUN) Создание администратора"
else
    sleep 5
    
    if sudo -u $GITEA_USER $GITEA_BINARY admin user list --config /etc/gitea/app.ini --work-path /var/lib/gitea 2>/dev/null | grep -q "$GITEA_ADMIN_USER"; then
        print_info "Администратор существует"
        log_info "Admin exists"
    else
        sudo -u $GITEA_USER $GITEA_BINARY admin user create \
            --username "$GITEA_ADMIN_USER" \
            --password "$GITEA_ADMIN_PASSWORD" \
            --email "$GITEA_ADMIN_EMAIL" \
            --work-path /var/lib/gitea \
            --admin \
            --config /etc/gitea/app.ini || {
            print_error "Не удалось создать администратора"
            log_error "Admin creation failed"
            [[ "$FORCE_MODE" != "true" ]] && exit 1
        }
        print_success "Администратор создан"
        log_success "Admin created"
    fi
fi

# --- Настройка NGINX ---
print_step "Создание конфигурации NGINX"
NGINX_CONF="/etc/nginx/sites-available/$GITEA_DOMAIN.conf"
NGINX_ENABLED="/etc/nginx/sites-enabled/$GITEA_DOMAIN.conf"

if [[ "$DRY_RUN" == "true" ]]; then
    print_warn "(DRY RUN) Создание NGINX конфигурации"
else
    # Создаем базовую HTTP конфигурацию
    cat > "$NGINX_CONF" <<EOF
upstream gitea {
    server 127.0.0.1:$GITEA_PORT;
}

server {
    listen 80;
    listen [::]:80;
    server_name $GITEA_DOMAIN;
    
    access_log /var/log/nginx/gitea_access.log;
    error_log /var/log/nginx/gitea_error.log;
    
    # Разрешаем доступ к .well-known для Let's Encrypt
    location ^~ /.well-known/acme-challenge/ {
        allow all;
        root /var/www/html;
        default_type "text/plain";
        try_files \$uri =404;
    }
    
    # Максимальный размер загружаемых файлов (для больших репозиториев)
    client_max_body_size 100M;
    
    location / {
        proxy_pass http://gitea;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        
        # WebSocket поддержка (для уведомлений)
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # Увеличенные таймауты для больших операций
        proxy_connect_timeout 600;
        proxy_send_timeout 600;
        proxy_read_timeout 600;
        send_timeout 600;
    }
}
EOF

    print_success "HTTP конфигурация NGINX создана"
    log_success "NGINX HTTP config created"
    
    if [[ ! -L "$NGINX_ENABLED" ]]; then
        ln -s "$NGINX_CONF" "$NGINX_ENABLED"
        print_success "Конфигурация активирована"
        log_success "NGINX config enabled"
    fi
    
    if nginx -t 2>/dev/null; then
        systemctl reload nginx
        print_success "NGINX перезагружен"
        log_success "NGINX reloaded"
    else
        print_error "Ошибка в конфигурации NGINX"
        log_error "NGINX config test failed"
        nginx -t
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
fi

# --- Настройка firewall ---
if [[ "${ENABLE_UFW:-true}" == "true" ]]; then
    print_step "Настройка firewall"
    if [[ "$DRY_RUN" == "true" ]]; then
        print_warn "(DRY RUN) ufw allow $GITEA_SSH_PORT/tcp"
    else
        if ufw allow $GITEA_SSH_PORT/tcp comment "Gitea SSH" >/dev/null 2>&1; then
            print_success "Порт $GITEA_SSH_PORT/tcp открыт"
            log_success "Firewall: $GITEA_SSH_PORT/tcp"
        else
            print_warning "Не удалось открыть порт"
            log_warning "Firewall rule failed"
        fi
    fi
fi

# --- Настройка SSL сертификата ---
if [[ "${ENABLE_SSL:-true}" == "true" ]] && [[ "$DRY_RUN" != "true" ]]; then
    print_section "🔒 НАСТРОЙКА SSL ДЛЯ GITEA"
    
    # Получаем SSL сертификат
    setup_ssl_certificate "$GITEA_DOMAIN" "/var/www/html"
    SSL_SETUP_RESULT=$?
    
    if [[ $SSL_SETUP_RESULT -eq 0 ]]; then
        # Получаем пути к сертификатам
        SSL_CERT=$(get_ssl_cert_path "$GITEA_DOMAIN")
        SSL_KEY=$(get_ssl_key_path "$GITEA_DOMAIN")
        
        print_step "Обновление NGINX конфига с HTTPS"
        log_info "Adding HTTPS configuration for Gitea"
        
        # Пересоздаем конфиг с HTTPS
        cat > "$NGINX_CONF" <<EOF
upstream gitea {
    server 127.0.0.1:$GITEA_PORT;
}

# HTTP сервер - редирект на HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name $GITEA_DOMAIN;
    
    # Разрешаем доступ к .well-known для Let's Encrypt
    location ^~ /.well-known/acme-challenge/ {
        allow all;
        root /var/www/html;
        default_type "text/plain";
        try_files \$uri =404;
    }
    
    # Редирект на HTTPS
    location / {
        return 301 https://\$server_name\$request_uri;
    }
}

# HTTPS сервер для Gitea
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $GITEA_DOMAIN;
    
    access_log /var/log/nginx/gitea_access.log;
    error_log /var/log/nginx/gitea_error.log;
    
    # SSL сертификаты
    ssl_certificate $SSL_CERT;
    ssl_certificate_key $SSL_KEY;
    
    # SSL настройки
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    
    # HSTS (раскомментируйте для продакшена)
    # add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    
    # Максимальный размер загружаемых файлов
    client_max_body_size 100M;
    
    location / {
        proxy_pass http://gitea;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port 443;
        
        # WebSocket поддержка
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # Увеличенные таймауты
        proxy_connect_timeout 600;
        proxy_send_timeout 600;
        proxy_read_timeout 600;
        send_timeout 600;
    }
}
EOF

        # Обновляем ROOT_URL в app.ini на HTTPS
        if [[ -f /etc/gitea/app.ini ]]; then
            sed -i "s|^ROOT_URL.*=.*|ROOT_URL = https://$GITEA_DOMAIN|g" /etc/gitea/app.ini
            log_info "Updated ROOT_URL to HTTPS in app.ini"
        fi
        
        # Проверяем и перезагружаем NGINX
        if nginx -t 2>/dev/null; then
            systemctl reload nginx
            print_success "HTTPS настроен для Gitea"
            log_info "NGINX reloaded with HTTPS configuration"
            
            # Перезапускаем Gitea для применения новых настроек
            systemctl restart gitea
            log_info "Gitea restarted with HTTPS configuration"
        else
            print_error "Ошибка в конфигурации NGINX"
            nginx -t
        fi
    else
        print_warning "SSL не настроен - Gitea работает только по HTTP"
        log_warn "SSL setup failed - Gitea running HTTP only"
    fi
else
    print_info "SSL отключен в конфигурации"
    log_info "SSL disabled"
fi

# --- Обновление DNS ---
if [[ -f "/etc/bind/zones/db.$DOMAIN" ]]; then
    print_step "Обновление DNS"
    if [[ "$DRY_RUN" == "true" ]]; then
        print_warn "(DRY RUN) Добавление DNS записи"
    else
        ZONE_FILE="/etc/bind/zones/db.$DOMAIN"
        GIT_SUBDOMAIN="${GITEA_DOMAIN%%.$DOMAIN}"
        
        if grep -q "^$GIT_SUBDOMAIN" "$ZONE_FILE"; then
            print_info "DNS запись существует"
            log_info "DNS record exists"
        else
            sed -i "/^@.*IN.*SOA/a $GIT_SUBDOMAIN    IN    A    $SERVER_IP" "$ZONE_FILE"
            CURRENT_SERIAL=$(grep -oP '(?<=serial: )\d+' "$ZONE_FILE" || echo "2024010101")
            NEW_SERIAL=$((CURRENT_SERIAL + 1))
            sed -i "s/$CURRENT_SERIAL/$NEW_SERIAL/g" "$ZONE_FILE"
            
            if systemctl reload bind9 2>/dev/null; then
                print_success "DNS запись добавлена"
                log_success "DNS record added"
            else
                print_warning "Не удалось перезагрузить BIND9"
                log_warning "BIND9 reload failed"
            fi
        fi
    fi
fi

# --- Проверка установки ---
print_step "Проверка установки"
if [[ "$DRY_RUN" != "true" ]]; then
    if systemctl is-active --quiet gitea; then
        print_success "Gitea работает"
        log_success "Gitea active"
    else
        print_error "Gitea не запущен"
        log_error "Gitea not active"
    fi
    
    if ss -tlnp | grep -q ":$GITEA_PORT"; then
        print_success "Порт $GITEA_PORT слушает"
        log_success "Port $GITEA_PORT listening"
    else
        print_warning "Порт $GITEA_PORT не слушает"
        log_warning "Port $GITEA_PORT not listening"
    fi
    
    if ss -tlnp | grep -q ":$GITEA_SSH_PORT"; then
        print_success "SSH порт $GITEA_SSH_PORT слушает"
        log_success "SSH port $GITEA_SSH_PORT listening"
    else
        print_warning "SSH порт не слушает"
        log_warning "SSH port not listening"
    fi
    
    if sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw "$GITEA_DB_NAME"; then
        print_success "База данных существует"
        log_success "Database exists"
    else
        print_error "База данных не найдена"
        log_error "Database not found"
    fi
    
    if nginx -t 2>/dev/null && [[ -f "$NGINX_ENABLED" ]]; then
        print_success "NGINX конфигурация корректна"
        log_success "NGINX config valid"
    else
        print_warning "Проблема с NGINX"
        log_warning "NGINX issue"
    fi
fi

# --- Итоговая информация ---
print_section "📦 GITEA УСТАНОВЛЕН"
print_success "✅ Git-сервер Gitea успешно установлен"
log_info "Gitea setup completed"

print_section "📌 ДОСТУП К GITEA"

# Выводим URL в зависимости от SSL
if [[ "${ENABLE_SSL:-true}" == "true" ]] && [[ ${SSL_SETUP_RESULT:-1} -eq 0 ]]; then
    print_info "   • Web URL:      https://$GITEA_DOMAIN"
    print_success "🔒 HTTPS включен - соединение защищено"
    log_info "Gitea accessible via HTTPS: https://$GITEA_DOMAIN"
else
    print_info "   • Web URL:      http://$GITEA_DOMAIN"
    print_warning "⚠️  HTTP режим - соединение не защищено"
    log_info "Gitea accessible via HTTP only: http://$GITEA_DOMAIN"
fi

print_info "   • SSH:          git@$GITEA_DOMAIN:$GITEA_SSH_PORT"

print_section "👤 УЧЕТНЫЕ ДАННЫЕ АДМИНИСТРАТОРА"
print_info "   • Логин:        $GITEA_ADMIN_USER"
print_info "   • Пароль:       GITEA_ADMIN_PASSWORD"
print_info "   • Email:        $GITEA_ADMIN_EMAIL"

print_section "⚙️  КОНФИГУРАЦИЯ"
print_info "   • База данных:  $GITEA_DB_NAME"
print_info "   • Репозитории:  /var/lib/gitea/data/gitea-repositories"
print_info "   • Конфигурация: /etc/gitea/app.ini"
print_info "   • HTTP порт:    $GITEA_PORT (внутренний)"
print_info "   • SSH порт:     $GITEA_SSH_PORT"

print_section "🔐 НАСТРОЙКИ БЕЗОПАСНОСТИ"
print_info "   • Регистрация:      $([ "$GITEA_DISABLE_REGISTRATION" == "true" ] && echo "отключена" || echo "включена")"
print_info "   • Публичный доступ: $([ "$GITEA_REQUIRE_SIGNIN" == "true" ] && echo "нет" || echo "да")"

if [[ "${ENABLE_SSL:-true}" != "true" ]] || [[ ${SSL_SETUP_RESULT:-1} -ne 0 ]]; then
    print_warning "   • ⚠️  Рекомендуется включить HTTPS для безопасности!"
fi

print_section "📋 УПРАВЛЕНИЕ GITEA"
print_color "DIM" "  Проверить статус:   systemctl status gitea"
print_color "DIM" "  Перезапустить:      systemctl restart gitea"
print_color "DIM" "  Посмотреть логи:    journalctl -u gitea -f"
print_color "DIM" "  Логи NGINX:         tail -f /var/log/nginx/gitea_error.log"

print_section "📥 КЛОНИРОВАНИЕ РЕПОЗИТОРИЕВ"
if [[ "${ENABLE_SSL:-true}" == "true" ]] && [[ ${SSL_SETUP_RESULT:-1} -eq 0 ]]; then
    print_info "HTTPS (рекомендуется):"
    print_color "DIM" "  git clone https://$GITEA_DOMAIN/username/repo.git"
else
    print_info "HTTP:"
    print_color "DIM" "  git clone http://$GITEA_DOMAIN/username/repo.git"
fi

print_info ""
print_info "SSH:"
print_color "DIM" "  git clone git@$GITEA_DOMAIN:username/repo.git"
print_color "DIM" "  (порт $GITEA_SSH_PORT - настроить в ~/.ssh/config)"

print_section "🔧 SSH КОНФИГУРАЦИЯ (~/.ssh/config)"
print_color "DIM" "  Host $GITEA_DOMAIN"
print_color "DIM" "      HostName $GITEA_DOMAIN"
print_color "DIM" "      Port $GITEA_SSH_PORT"
print_color "DIM" "      User git"
print_color "DIM" "      IdentityFile ~/.ssh/id_rsa"

print_section "👥 ДОБАВИТЬ ПОЛЬЗОВАТЕЛЯ"
print_color "DIM" "  sudo -u git /usr/local/bin/gitea admin user create \\"
print_color "DIM" "      --username \"user\" \\"
print_color "DIM" "      --password \"password\" \\"
print_color "DIM" "      --email \"user@$DOMAIN\" \\"
print_color "DIM" "      --config /etc/gitea/app.ini"

if [[ "${ENABLE_SSL:-true}" == "true" ]] && [[ ${SSL_SETUP_RESULT:-1} -eq 0 ]]; then
    print_info ""
    print_section "🔍 ПРОВЕРКА SSL"
    print_color "DIM" "  Браузер:     https://$GITEA_DOMAIN"
    print_color "DIM" "  SSL Test:    https://www.ssllabs.com/ssltest/analyze.html?d=$GITEA_DOMAIN"
fi

print_info ""
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Gitea setup completed:"
log_info "  URL: $([ ${SSL_SETUP_RESULT:-1} -eq 0 ] && echo "https" || echo "http")://$GITEA_DOMAIN"
log_info "  Admin: $GITEA_ADMIN_USER"
log_info "  SSH: git@$GITEA_DOMAIN:$GITEA_SSH_PORT"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

print_success "✅ Модуль Git-сервера (Gitea) завершён"
log_info "Модуль 18-git-gitea.sh завершён успешно"
