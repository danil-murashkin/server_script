#!/bin/bash
# modules/15-webmail-roundcube.sh - Установка и настройка Roundcube Webmail
# Часть Mail Server Deployment Module System

# --- Загрузка утилит ---
[[ -z "${UTIL_PRINT_LOADED}" ]] && source ./utils/print.sh 2>/dev/null
[[ -z "${UTIL_LOGGING_LOADED}" ]] && source ./utils/logging.sh 2>/dev/null
[[ -z "${UTIL_FUNCTIONS_LOADED}" ]] && source ./utils/functions.sh 2>/dev/null

# --- Проверка прав root ---
ensure_root

# --- Загрузка конфигурации ---
load_config || {
    print_error "Не удалось загрузить конфигурацию"
    log_error "Failed to load configuration"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
}

# --- Проверка включения модуля ---
if [[ "${ENABLE_MAIL:-true}" != "true" ]]; then
    print_warning "Почтовый сервер отключен в конфигурации (ENABLE_MAIL=false)"
    log_info "Mail server installation skipped (ENABLE_MAIL=false)"
    exit 0
fi

# --- Проверка обязательных переменных ---
for var in DOMAIN ADMIN_EMAIL ADMIN_PASSWORD ROUNDCUBE_DB_NAME ROUNDCUBE_DB_USER ROUNDCUBE_DB_PASSWORD; do
    if [[ -z "${!var}" ]]; then
        print_error "Переменная $var не задана"
        log_error "Required variable $var is missing"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
done

# --- Проверка наличия необходимых команд ---
require_command "nginx" "веб-сервер"
require_command "psql" "PostgreSQL клиент"
require_command "php" "PHP интерпретатор"
require_command "wget" "загрузка архивов"

print_step "Установка Roundcube Webmail"

# --- 1. Установка PHP-зависимостей ---
if [[ "$DRY_RUN" != "true" ]]; then
    print_info "Установка PHP-расширений для Roundcube..."
    apt-get update >/dev/null 2>&1
    apt-get install -y php-{gd,intl,mbstring,json,xml,zip,curl,pgsql,imap,pspell} >/dev/null 2>&1
    systemctl reload php*-fpm >/dev/null 2>&1 || true
    log_info "PHP extensions installed"
else
    print_info "[DRY RUN] Пропуск установки PHP-расширений"
fi

# --- 2. Скачивание и распаковка Roundcube ---
ROUNDCUBE_VERSION="1.6.9"
ROUNDCUBE_DIR="/var/www/roundcube"
DOWNLOAD_URL="https://github.com/roundcube/roundcubemail/releases/download/${ROUNDCUBE_VERSION}/roundcubemail-${ROUNDCUBE_VERSION}-complete.tar.gz"

if [[ "$DRY_RUN" != "true" ]]; then
    print_info "Скачивание Roundcube $ROUNDCUBE_VERSION..."
    safe_mkdir "/var/www" "www-data" "755"
    wget -q -O /tmp/roundcube.tar.gz "$DOWNLOAD_URL" || {
        print_error "Не удалось скачать Roundcube"
        log_error "Failed to download Roundcube"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    }

    mkdir -p /tmp/roundcube_extract
    tar -xzf /tmp/roundcube.tar.gz -C /tmp/roundcube_extract || {
        print_error "Ошибка распаковки Roundcube"
        log_error "Failed to extract Roundcube"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    }

    SRC_DIR=$(ls /tmp/roundcube_extract | head -1)
    if [[ -z "$SRC_DIR" ]]; then
        print_error "Не удалось определить имя распакованной директории"
        exit 1
    fi

    safe_mkdir "$ROUNDCUBE_DIR" "www-data" "755"
    cp -r /tmp/roundcube_extract/"$SRC_DIR"/* "$ROUNDCUBE_DIR/" 2>/dev/null
    cp -r /tmp/roundcube_extract/"$SRC_DIR"/.[^.]* "$ROUNDCUBE_DIR/" 2>/dev/null || true

    rm -rf /tmp/roundcube.tar.gz /tmp/roundcube_extract
    chown -R www-data:www-data "$ROUNDCUBE_DIR"
    log_info "Roundcube extracted to $ROUNDCUBE_DIR"
else
    print_info "[DRY RUN] Пропуск скачивания и распаковки Roundcube"
fi

# --- 3. Настройка PostgreSQL: ОТДЕЛЬНАЯ БД для Roundcube ---
# ВАЖНО: Roundcube использует свою собственную БД, отдельную от почтовой системы
DB_NAME="${ROUNDCUBE_DB_NAME}"
DB_USER="${ROUNDCUBE_DB_USER}"
DB_PASS="${ROUNDCUBE_DB_PASSWORD}"

if [[ "$DRY_RUN" != "true" ]]; then
    print_info "Настройка PostgreSQL для Roundcube..."

    # Удаляем старого пользователя и БД при --force
    if [[ "$FORCE_MODE" == "true" ]]; then
        sudo -u postgres psql -c "DROP DATABASE IF EXISTS $DB_NAME;" >/dev/null 2>&1
        sudo -u postgres psql -c "DROP USER IF EXISTS $DB_USER;" >/dev/null 2>&1
    fi

    # Создаём или обновляем пользователя
    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER';" | grep -q "1"; then
        print_info "Пользователь '$DB_USER' существует — обновляем пароль"
        ESCAPED_PASS=$(printf '%s\n' "$DB_PASS" | sed "s/'/''/g")
        sudo -u postgres psql -c "ALTER USER $DB_USER PASSWORD '$ESCAPED_PASS';" >/dev/null 2>&1
    else
        ESCAPED_PASS=$(printf '%s\n' "$DB_PASS" | sed "s/'/''/g")
        sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$ESCAPED_PASS';" >/dev/null 2>&1
    fi

    # Создаём БД, если не существует
    if ! sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
        sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;" >/dev/null 2>&1
    fi

    # Проверяем наличие таблиц и инициализируем при необходимости
    if ! sudo -u postgres psql -d "$DB_NAME" -tAc "SELECT tablename FROM pg_tables WHERE schemaname='public' AND tablename='session';" | grep -q "session"; then
        print_info "Таблицы отсутствуют — инициализируем схему Roundcube"
        sudo -u postgres psql -d "$DB_NAME" -f "$ROUNDCUBE_DIR/SQL/postgres.initial.sql" >/dev/null 2>&1
        
        # Предоставляем права доступа
        print_info "Настройка прав доступа к таблицам..."
        sudo -u postgres psql -d "$DB_NAME" << EOSQL >/dev/null 2>&1
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO $DB_USER;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO $DB_USER;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON TABLES TO $DB_USER;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON SEQUENCES TO $DB_USER;
EOSQL
        log_info "Roundcube database initialized"
    else
        print_info "Таблицы Roundcube уже существуют — проверяем права доступа"
        # Проверяем и исправляем права доступа
        if ! sudo -u postgres psql -d "$DB_NAME" -tAc "SELECT 1 FROM information_schema.table_privileges WHERE grantee='$DB_USER' AND table_name='session' AND privilege_type='SELECT';" | grep -q "1"; then
            print_info "Права доступа отсутствуют — исправляем"
            sudo -u postgres psql -d "$DB_NAME" << EOSQL >/dev/null 2>&1
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO $DB_USER;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO $DB_USER;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON TABLES TO $DB_USER;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON SEQUENCES TO $DB_USER;
EOSQL
            log_info "Database permissions fixed"
        fi
    fi

    log_info "PostgreSQL setup completed for Roundcube"
else
    print_info "[DRY RUN] Пропуск настройки PostgreSQL"
fi

# --- 4. Генерация конфигурации Roundcube ---
CONFIG_FILE="$ROUNDCUBE_DIR/config/config.inc.php"

if [[ "$DRY_RUN" != "true" ]]; then
    print_info "Генерация конфигурации Roundcube..."

    safe_mkdir "$ROUNDCUBE_DIR/config" "www-data" "750"
    safe_mkdir "$ROUNDCUBE_DIR/temp" "www-data" "755"
    safe_mkdir "$ROUNDCUBE_DIR/logs" "www-data" "755"
    safe_touch "$CONFIG_FILE" "www-data" "640"

    cat > "$CONFIG_FILE" <<EOF
<?php
\$config = array();

// База данных Roundcube (отдельная от почтовой системы)
\$config['db_dsnw'] = 'pgsql://$DB_USER:$DB_PASS@localhost/$DB_NAME';

// Подключение к почтовому серверу
\$config['default_host'] = 'localhost';
\$config['default_port'] = 143;
\$config['imap_auth_type'] = 'PLAIN';
\$config['smtp_server'] = 'localhost';
\$config['smtp_port'] = 587;
\$config['smtp_user'] = '%u';
\$config['smtp_pass'] = '%p';
\$config['smtp_auth_type'] = 'PLAIN';

// Основные настройки
\$config['support_url'] = '';
\$config['product_name'] = 'Webmail @ $DOMAIN';
\$config['des_key'] = '$(openssl rand -hex 24)';
\$config['temp_dir'] = '$ROUNDCUBE_DIR/temp';
\$config['log_dir'] = '/var/log/roundcube/';
\$config['plugins'] = array('archive', 'zipdownload', 'managesieve');

// Интерфейс
\$config['skin'] = 'elastic';
\$config['language'] = 'ru_RU';
\$config['spellcheck_engine'] = 'pspell';
\$config['username_domain'] = '$DOMAIN';

// Дополнительные настройки
\$config['debug_level'] = 1;
\$config['log_logins'] = true;
\$config['session_lifetime'] = 10;
\$config['session_domain'] = '';
\$config['session_name'] = 'roundcube_sessid';
\$config['session_storage'] = 'db';

// Настройки безопасности
\$config['force_https'] = false;
\$config['use_https'] = false;
\$config['login_autocomplete'] = 2;
\$config['password_charset'] = 'UTF-8';

// Настройки IMAP
\$config['imap_timeout'] = 0;
\$config['imap_auth_type'] = null;
\$config['imap_delimiter'] = null;
\$config['imap_ns_personal'] = null;
\$config['imap_ns_other'] = null;
\$config['imap_ns_shared'] = null;

// Настройки SMTP
\$config['smtp_timeout'] = 0;
\$config['smtp_helo_host'] = '';
?>
EOF

    chown www-data:www-data "$CONFIG_FILE"
    chmod 640 "$CONFIG_FILE"
    safe_mkdir "/var/log/roundcube" "www-data" "755"
    log_info "Roundcube config written"
else
    print_info "[DRY RUN] Пропуск генерации конфигурации"
fi

# --- 5. Настройка NGINX ---
NGINX_SITE="/etc/nginx/sites-available/${ROUNDCUBE_SUBDOMAIN:-webmail}.$DOMAIN"
NGINX_LINK="/etc/nginx/sites-enabled/${ROUNDCUBE_SUBDOMAIN:-webmail}.$DOMAIN"
ROUNDCUBE_FULL_DOMAIN="${ROUNDCUBE_SUBDOMAIN:-webmail}.$DOMAIN"

if [[ "$DRY_RUN" != "true" ]]; then
    print_info "Настройка NGINX для $ROUNDCUBE_FULL_DOMAIN..."

    # Создаем базовую HTTP конфигурацию
    cat > "$NGINX_SITE" <<EOF
# HTTP сервер для Roundcube
server {
    listen 80;
    server_name $ROUNDCUBE_FULL_DOMAIN;
    root $ROUNDCUBE_DIR;
    index index.php;

    access_log /var/log/nginx/roundcube.access.log;
    error_log /var/log/nginx/roundcube.error.log;

    # Разрешаем доступ к .well-known для Let's Encrypt
    location ^~ /.well-known/acme-challenge/ {
        allow all;
        root $ROUNDCUBE_DIR;
        default_type "text/plain";
        try_files \$uri =404;
    }

    # Максимальный размер загружаемых файлов (для вложений)
    client_max_body_size 50M;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    # Запретить доступ к скрытым файлам и директориям
    location ~ /\. {
        deny all;
    }

    # Запретить доступ к конфигурационным директориям
    location ~ ^/(config|temp|logs|SQL|bin|program)/ {
        deny all;
    }

    # Кэширование статических файлов
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)\$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        access_log off;
    }
}
EOF

    ln -sf "$NGINX_SITE" "$NGINX_LINK"
    nginx -t >/dev/null 2>&1 || {
        print_error "Ошибка в конфигурации NGINX"
        log_error "Nginx config test failed"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    }
    systemctl reload nginx
    log_info "Nginx HTTP configuration created for $ROUNDCUBE_FULL_DOMAIN"
else
    print_info "[DRY RUN] Пропуск настройки NGINX"
fi

# --- 6. SSL ---
if [[ "${ENABLE_SSL:-true}" == "true" ]] && [[ "$DRY_RUN" != "true" ]]; then
    print_section "🔒 НАСТРОЙКА SSL ДЛЯ ROUNDCUBE"
    
    # Получаем SSL сертификат
    setup_ssl_certificate "$ROUNDCUBE_FULL_DOMAIN" "$ROUNDCUBE_DIR"
    SSL_SETUP_RESULT=$?
    
    if [[ $SSL_SETUP_RESULT -eq 0 ]]; then
        # Получаем пути к сертификатам
        SSL_CERT=$(get_ssl_cert_path "$ROUNDCUBE_FULL_DOMAIN")
        SSL_KEY=$(get_ssl_key_path "$ROUNDCUBE_FULL_DOMAIN")
        
        print_step "Обновление NGINX конфига с HTTPS"
        log_info "Adding HTTPS configuration for Roundcube"
        
        # Пересоздаем конфиг с HTTPS
        cat > "$NGINX_SITE" <<EOF
# HTTP сервер - редирект на HTTPS
server {
    listen 80;
    server_name $ROUNDCUBE_FULL_DOMAIN;

    # Разрешаем доступ к .well-known для Let's Encrypt
    location ^~ /.well-known/acme-challenge/ {
        allow all;
        root $ROUNDCUBE_DIR;
        default_type "text/plain";
        try_files \$uri =404;
    }

    # Редирект на HTTPS
    location / {
        return 301 https://\$server_name\$request_uri;
    }
}

# HTTPS сервер для Roundcube
server {
    listen 443 ssl http2;
    server_name $ROUNDCUBE_FULL_DOMAIN;
    root $ROUNDCUBE_DIR;
    index index.php;

    access_log /var/log/nginx/roundcube.access.log;
    error_log /var/log/nginx/roundcube.error.log;

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
    client_max_body_size 50M;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        
        # Увеличенные таймауты для работы с большими письмами
        fastcgi_read_timeout 300;
        fastcgi_send_timeout 300;
    }

    # Запретить доступ к скрытым файлам
    location ~ /\. {
        deny all;
    }

    # Запретить доступ к конфигурационным директориям
    location ~ ^/(config|temp|logs|SQL|bin|program)/ {
        deny all;
    }

    # Кэширование статических файлов
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)\$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        access_log off;
    }
}
EOF

        # Обновляем конфигурацию Roundcube для HTTPS
        if [[ -f "$CONFIG_FILE" ]]; then
            sed -i "s/\$config\['force_https'\] = false;/\$config['force_https'] = true;/" "$CONFIG_FILE"
            sed -i "s/\$config\['use_https'\] = false;/\$config['use_https'] = true;/" "$CONFIG_FILE"
            log_info "HTTPS settings updated in config.inc.php"
        fi
        
        # Проверяем и перезагружаем NGINX
        if nginx -t >/dev/null 2>&1; then
            systemctl reload nginx
            print_success "HTTPS настроен для Roundcube"
            log_info "NGINX reloaded with HTTPS configuration"
        else
            print_error "Ошибка в конфигурации NGINX"
            nginx -t
        fi
    else
        print_warning "SSL не настроен - Roundcube работает только по HTTP"
        log_warn "SSL setup failed - Roundcube running HTTP only"
        print_warning "⚠️  ВНИМАНИЕ: Использование веб-почты без HTTPS ОПАСНО!"
    fi
else
    print_info "SSL отключен в конфигурации"
    log_info "SSL disabled"
    if [[ "$DRY_RUN" != "true" ]]; then
        print_warning "⚠️  ВНИМАНИЕ: Использование веб-почты без HTTPS ОПАСНО!"
    fi
fi

# --- 7. Финальная проверка и очистка ---
if [[ "$DRY_RUN" != "true" ]]; then
    print_info "Финальная проверка установки..."
    
    # Проверяем права доступа
    chown -R www-data:www-data "$ROUNDCUBE_DIR"
    find "$ROUNDCUBE_DIR" -type d -exec chmod 755 {} \;
    find "$ROUNDCUBE_DIR" -type f -exec chmod 644 {} \;
    chmod 640 "$CONFIG_FILE"
    
    # Проверяем подключение к БД Roundcube
    if ! PGPASSWORD="$DB_PASS" psql -h localhost -U "$DB_USER" -d "$DB_NAME" -c "\q" 2>/dev/null; then
        print_error "Не удалось подключиться к базе данных Roundcube"
        log_error "Database connection test failed"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
    
    log_info "Roundcube setup completed"
else
    print_info "[DRY RUN] Пропуск финальной проверки"
fi

# --- Информация ---
print_section "📮 ROUNDCUBE УСТАНОВЛЕН"
print_success "✅ Roundcube успешно установлен"
log_info "Roundcube installation completed"

print_section "📌 ДОСТУП К ROUNDCUBE"

# Выводим URL в зависимости от SSL
if [[ "${ENABLE_SSL:-true}" == "true" ]] && [[ ${SSL_SETUP_RESULT:-1} -eq 0 ]]; then
    print_info "   • URL:      https://$ROUNDCUBE_FULL_DOMAIN"
    print_success "🔒 HTTPS включен - веб-почта защищена"
    log_info "Roundcube accessible via HTTPS: https://$ROUNDCUBE_FULL_DOMAIN"
else
    print_info "   • URL:      http://$ROUNDCUBE_FULL_DOMAIN"
    print_warning "⚠️  HTTP режим - соединение НЕ защищено!"
    print_warning "⚠️  Пароли передаются открытым текстом!"
    log_info "Roundcube accessible via HTTP only: http://$ROUNDCUBE_FULL_DOMAIN"
fi

print_info ""
print_info "База данных Roundcube (отдельная):"
print_info "   • Имя: $DB_NAME"
print_info "   • Пользователь: $DB_USER"
print_info ""
print_info "Почтовый сервер (для входа):"
print_info "   • IMAP: localhost:143"
print_info "   • SMTP: localhost:587"
print_info ""
print_info "Для входа используйте:"
print_info "   • Email: пользователь@$DOMAIN"
print_info "   • Пароль: пароль почтового ящика"
print_info ""
print_warning "ВАЖНО: Roundcube использует свою отдельную БД '$DB_NAME'"
print_warning "Почтовые данные находятся в БД '${MAIL_DB_NAME}' (PostfixAdmin)"

if [[ "${ENABLE_SSL:-true}" != "true" ]] || [[ ${SSL_SETUP_RESULT:-1} -ne 0 ]]; then
    print_info ""
    print_section "⚠️  РЕКОМЕНДАЦИЯ ПО БЕЗОПАСНОСТИ"
    print_warning "Включите HTTPS для защиты паролей!"
    print_color "DIM" "  Установите ENABLE_SSL=true в main.conf"
    print_color "DIM" "  Перезапустите установку модуля 15-webmail-roundcube.sh"
fi

log_info "Roundcube installation completed"
