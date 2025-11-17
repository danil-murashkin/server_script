#!/bin/bash
# modules/19-cloud-nextcloud.sh - Установка и настройка облачного хранилища NextCloud
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
if [[ "${ENABLE_NEXTCLOUD:-false}" != "true" ]]; then
    print_warning "NextCloud отключен в конфигурации (ENABLE_NEXTCLOUD=false)"
    log_info "NextCloud installation skipped (ENABLE_NEXTCLOUD=false)"
    exit 0
fi

# --- Проверка переменных ---
print_step "Проверка конфигурации NextCloud"

NEXTCLOUD_VERSION="${NEXTCLOUD_VERSION:-32.0.1}"
NEXTCLOUD_SUBDOMAIN="${NEXTCLOUD_SUBDOMAIN:-cloud}"
NEXTCLOUD_DOMAIN="${NEXTCLOUD_DOMAIN:-$NEXTCLOUD_SUBDOMAIN.$DOMAIN}"
NEXTCLOUD_DIR="/var/www/nextcloud"
NEXTCLOUD_DATA_DIR="${NEXTCLOUD_DATA_DIR:-/var/www/nextcloud-data}"
NEXTCLOUD_DB_NAME="${NEXTCLOUD_DB_NAME:-nextcloud}"
NEXTCLOUD_DB_USER="${NEXTCLOUD_DB_USER:-nextcloud}"
NEXTCLOUD_DB_PASSWORD="${NEXTCLOUD_DB_PASSWORD:-$ADMIN_PASSWORD}"
NEXTCLOUD_ADMIN_USER="${NEXTCLOUD_ADMIN_USER:-admin}"
NEXTCLOUD_ADMIN_PASSWORD="${NEXTCLOUD_ADMIN_PASSWORD:-$ADMIN_PASSWORD}"
NEXTCLOUD_ADMIN_EMAIL="${NEXTCLOUD_ADMIN_EMAIL:-$ADMIN_EMAIL}"

log_info "NextCloud URL: https://$NEXTCLOUD_DOMAIN"
log_info "Версия: $NEXTCLOUD_VERSION"
log_info "Директория: $NEXTCLOUD_DIR"

print_info "Устанавливаемая версия: $NEXTCLOUD_VERSION"
print_info "URL скачивания: https://download.nextcloud.com/server/releases/nextcloud-$NEXTCLOUD_VERSION.zip"

# --- Проверка ОС ---
ensure_debian || {
    print_error "Поддерживается только Debian 11+"
    log_error "Unsupported OS"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
}

# --- Проверка зависимостей ---
require_command "psql" "PostgreSQL (модуль 09)"
require_command "nginx" "NGINX (модуль 08)"
require_command "php" "PHP (модуль 10)"

if ! sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw postgres; then
    print_error "PostgreSQL не работает"
    log_error "PostgreSQL not running"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# --- Создание директорий ---
print_step "Создание директорий NextCloud"
if [[ "$DRY_RUN" == "true" ]]; then
    print_warn "(DRY RUN) mkdir -p $NEXTCLOUD_DIR $NEXTCLOUD_DATA_DIR"
else
    mkdir -p "$NEXTCLOUD_DIR" "$NEXTCLOUD_DATA_DIR" || {
        print_error "Не удалось создать директории"
        log_error "Failed to create directories"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    }
    print_success "Директории созданы"
    log_success "Directories created"
fi

# --- Скачивание NextCloud ---
print_step "Скачивание NextCloud $NEXTCLOUD_VERSION"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEXTCLOUD_URL="https://download.nextcloud.com/server/releases/nextcloud-$NEXTCLOUD_VERSION.zip"
NEXTCLOUD_ZIP="$SCRIPT_DIR/nextcloud-$NEXTCLOUD_VERSION.zip"
NEXTCLOUD_MD5_URL="https://download.nextcloud.com/server/releases/nextcloud-$NEXTCLOUD_VERSION.zip.md5"
MIN_SIZE=100000000  # Минимальный размер архива ~100MB

if [[ "$DRY_RUN" == "true" ]]; then
    print_warn "(DRY RUN) curl -# -L $NEXTCLOUD_URL -o $NEXTCLOUD_ZIP"
else
    # Проверяем, был ли уже скачан архив
    NEED_DOWNLOAD=false
    
    if [[ -f "$NEXTCLOUD_ZIP" ]]; then
        # Проверяем размер файла
        ARCHIVE_SIZE=$(stat -c%s "$NEXTCLOUD_ZIP" 2>/dev/null || echo "0")
        
        if [[ $ARCHIVE_SIZE -lt $MIN_SIZE ]]; then
            print_warning "Архив поврежден или не полностью скачан (размер: $ARCHIVE_SIZE байт)"
            log_warning "Archive incomplete or corrupted, size: $ARCHIVE_SIZE bytes"
            rm -f "$NEXTCLOUD_ZIP"
            NEED_DOWNLOAD=true
        else
            # Проверяем целостность архива
            if unzip -t "$NEXTCLOUD_ZIP" >/dev/null 2>&1; then
                print_info "Архив NextCloud уже скачан и проверен: $NEXTCLOUD_ZIP"
                log_info "NextCloud archive already downloaded and verified: $NEXTCLOUD_ZIP"
            else
                print_warning "Архив поврежден, будет скачан заново"
                log_warning "Archive corrupted, re-downloading"
                rm -f "$NEXTCLOUD_ZIP"
                NEED_DOWNLOAD=true
            fi
        fi
    else
        NEED_DOWNLOAD=true
    fi
    
    # Скачиваем если нужно
    if [[ "$NEED_DOWNLOAD" == "true" ]]; then
        log_info "Downloading from: $NEXTCLOUD_URL to $NEXTCLOUD_ZIP"
        print_info "Скачивание NextCloud $NEXTCLOUD_VERSION..."
        
        if curl -# -L "$NEXTCLOUD_URL" -o "$NEXTCLOUD_ZIP"; then
            echo ""
            
            # Проверяем размер скачанного файла
            ARCHIVE_SIZE=$(stat -c%s "$NEXTCLOUD_ZIP" 2>/dev/null || echo "0")
            if [[ $ARCHIVE_SIZE -lt $MIN_SIZE ]]; then
                print_error "Скачанный файл слишком мал (размер: $ARCHIVE_SIZE байт)"
                log_error "Downloaded file too small: $ARCHIVE_SIZE bytes"
                rm -f "$NEXTCLOUD_ZIP"
                [[ "$FORCE_MODE" != "true" ]] && exit 1
            fi
            
            # Проверяем целостность ZIP
            if unzip -t "$NEXTCLOUD_ZIP" >/dev/null 2>&1; then
                print_success "NextCloud скачан и проверен: $NEXTCLOUD_ZIP"
                log_success "NextCloud downloaded and verified: $NEXTCLOUD_ZIP"
            else
                print_error "Скачанный архив поврежден"
                log_error "Downloaded archive is corrupted"
                rm -f "$NEXTCLOUD_ZIP"
                [[ "$FORCE_MODE" != "true" ]] && exit 1
            fi
        else
            print_error "Не удалось скачать NextCloud"
            print_info "URL: $NEXTCLOUD_URL"
            log_error "Download failed from $NEXTCLOUD_URL"
            [[ "$FORCE_MODE" != "true" ]] && exit 1
        fi
    fi
    
    # Проверяем, установлен ли уже NextCloud
    if [[ -f "$NEXTCLOUD_DIR/version.php" ]]; then
        CURRENT_VERSION=$(grep "OC_VersionString" "$NEXTCLOUD_DIR/version.php" | cut -d"'" -f2 || echo "unknown")
        if [[ "$CURRENT_VERSION" == "$NEXTCLOUD_VERSION" ]]; then
            print_info "NextCloud $NEXTCLOUD_VERSION уже установлен"
            log_info "NextCloud already installed: $CURRENT_VERSION"
            SKIP_EXTRACTION=true
        else
            print_info "Обновление NextCloud: $CURRENT_VERSION → $NEXTCLOUD_VERSION"
            log_info "Updating NextCloud: $CURRENT_VERSION → $NEXTCLOUD_VERSION"
        fi
    fi
    
    # Распаковываем, если нужно
    if [[ "$SKIP_EXTRACTION" != "true" ]]; then
        print_step "Распаковка NextCloud из $NEXTCLOUD_ZIP"
        
        # Удаляем старую версию если есть
        if [[ -d "$NEXTCLOUD_DIR" ]]; then
            print_info "Создание резервной копии..."
            mv "$NEXTCLOUD_DIR" "${NEXTCLOUD_DIR}.backup.$(date +%Y%m%d_%H%M%S)"
        fi
        
        if unzip -q "$NEXTCLOUD_ZIP" -d /var/www/ 2>/dev/null; then
            print_success "NextCloud распакован"
            log_success "NextCloud extracted from $NEXTCLOUD_ZIP"
        else
            print_error "Не удалось распаковать архив"
            log_error "Extraction failed"
            [[ "$FORCE_MODE" != "true" ]] && exit 1
        fi
    fi
fi

# --- Настройка прав доступа ---
print_step "Настройка прав доступа"
if [[ "$DRY_RUN" != "true" ]]; then
    chown -R www-data:www-data "$NEXTCLOUD_DIR" "$NEXTCLOUD_DATA_DIR"
    chmod -R 750 "$NEXTCLOUD_DATA_DIR"
    find "$NEXTCLOUD_DIR" -type d -exec chmod 755 {} \;
    find "$NEXTCLOUD_DIR" -type f -exec chmod 644 {} \;
    print_success "Права настроены"
    log_success "Permissions configured"
fi

# --- Создание пользователя БД ---
print_step "Создание пользователя БД: $NEXTCLOUD_DB_USER"
if [[ "$DRY_RUN" == "true" ]]; then
    print_warn "(DRY RUN) Создание пользователя БД"
else
    if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$NEXTCLOUD_DB_USER'" | grep -q 1; then
        print_info "Пользователь БД существует"
        log_info "DB user exists"
    else
        sudo -u postgres psql -c "CREATE USER $NEXTCLOUD_DB_USER WITH PASSWORD '$NEXTCLOUD_DB_PASSWORD';" || {
            print_error "Не удалось создать пользователя БД"
            log_error "DB user creation failed"
            [[ "$FORCE_MODE" != "true" ]] && exit 1
        }
        print_success "Пользователь БД создан"
        log_success "DB user created"
    fi
fi

# --- Создание базы данных ---
print_step "Создание базы данных: $NEXTCLOUD_DB_NAME"
if [[ "$DRY_RUN" == "true" ]]; then
    print_warn "(DRY RUN) Создание БД"
else
    if sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw "$NEXTCLOUD_DB_NAME"; then
        print_info "База данных существует"
        log_info "Database exists"
    else
        sudo -u postgres psql -c "CREATE DATABASE $NEXTCLOUD_DB_NAME OWNER $NEXTCLOUD_DB_USER;" || {
            print_error "Не удалось создать БД"
            log_error "DB creation failed"
            [[ "$FORCE_MODE" != "true" ]] && exit 1
        }
        print_success "База данных создана"
        log_success "Database created"
    fi
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $NEXTCLOUD_DB_NAME TO $NEXTCLOUD_DB_USER;"
    log_success "DB privileges granted"
fi

# --- Настройка NGINX ---
print_step "Создание конфигурации NGINX"
NGINX_CONF="/etc/nginx/sites-available/$NEXTCLOUD_DOMAIN.conf"
NGINX_ENABLED="/etc/nginx/sites-enabled/$NEXTCLOUD_DOMAIN.conf"

if [[ "$DRY_RUN" == "true" ]]; then
    print_warn "(DRY RUN) Создание NGINX конфигурации"
else
    # Создаем временную HTTP-only конфигурацию для получения SSL
    cat > "$NGINX_CONF" <<'EOF'
upstream php-handler {
    server unix:/run/php/php8.2-fpm.sock;
}

server {
    listen 80;
    listen [::]:80;
    server_name NEXTCLOUD_DOMAIN_PLACEHOLDER;
    
    root NEXTCLOUD_DIR_PLACEHOLDER;
    index index.php;
    
    client_max_body_size 10G;
    
    # Для получения SSL сертификата
    location ^~ /.well-known/acme-challenge {
        default_type "text/plain";
        root /var/www/letsencrypt;
    }
    
    location / {
        try_files $uri $uri/ /index.php$request_uri;
    }
    
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass php-handler;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
    }
}
EOF

    sed -i "s|NEXTCLOUD_DOMAIN_PLACEHOLDER|$NEXTCLOUD_DOMAIN|g" "$NGINX_CONF"
    sed -i "s|NEXTCLOUD_DIR_PLACEHOLDER|$NEXTCLOUD_DIR|g" "$NGINX_CONF"
    
    print_success "Конфигурация NGINX создана (HTTP)"
    log_success "NGINX config created (HTTP)"
    
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

# --- Настройка SSL сертификата ---
if [[ "${ENABLE_SSL:-true}" == "true" ]] && [[ "${SSL_PROVIDER:-letsencrypt}" == "letsencrypt" ]]; then
    if [[ "$DRY_RUN" != "true" ]]; then
        if command -v certbot &>/dev/null; then
            print_step "Получение SSL сертификата"
            mkdir -p /var/www/letsencrypt
            
            CERTBOT_OPTS="--webroot -w /var/www/letsencrypt -d $NEXTCLOUD_DOMAIN --non-interactive --agree-tos --email $ADMIN_EMAIL --quiet"
            [[ "${SSL_USE_STAGING:-false}" == "true" ]] && CERTBOT_OPTS+=" --staging"
            
            if certbot certonly $CERTBOT_OPTS >/dev/null 2>&1; then
                print_success "SSL сертификат получен"
                log_success "SSL certificate obtained for $NEXTCLOUD_DOMAIN"
                
                # Теперь создаем полную конфигурацию с HTTPS
                print_step "Обновление конфигурации NGINX для HTTPS"
                cat > "$NGINX_CONF" <<'EOF'
upstream php-handler {
    server unix:/run/php/php8.2-fpm.sock;
}

map $arg_v $asset_immutable {
    "" "";
    default "immutable";
}

server {
    listen 80;
    listen [::]:80;
    server_name NEXTCLOUD_DOMAIN_PLACEHOLDER;
    
    location ^~ /.well-known/acme-challenge {
        default_type "text/plain";
        root /var/www/letsencrypt;
    }
    
    location / {
        return 301 https://$server_name$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name NEXTCLOUD_DOMAIN_PLACEHOLDER;
    
    ssl_certificate /etc/letsencrypt/live/NEXTCLOUD_DOMAIN_PLACEHOLDER/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/NEXTCLOUD_DOMAIN_PLACEHOLDER/privkey.pem;
    
    root NEXTCLOUD_DIR_PLACEHOLDER;
    
    client_max_body_size 10G;
    client_body_timeout 300s;
    fastcgi_buffers 64 4K;
    
    gzip on;
    gzip_vary on;
    gzip_comp_level 4;
    gzip_min_length 256;
    gzip_proxied expired no-cache no-store private no_last_modified no_etag auth;
    gzip_types application/atom+xml text/javascript application/javascript application/json application/ld+json application/manifest+json application/rss+xml application/vnd.geo+json application/vnd.ms-fontobject application/wasm application/x-font-ttf application/x-web-app-manifest+json application/xhtml+xml application/xml font/opentype image/bmp image/svg+xml image/x-icon text/cache-manifest text/css text/plain text/vcard text/vnd.rim.location.xloc text/vtt text/x-component text/x-cross-domain-policy;
    
    add_header Referrer-Policy "no-referrer" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Permitted-Cross-Domain-Policies "none" always;
    add_header X-Robots-Tag "noindex, nofollow" always;
    add_header X-XSS-Protection "1; mode=block" always;
    
    fastcgi_hide_header X-Powered-By;
    
    index index.php index.html /index.php$request_uri;
    
    location = / {
        if ( $http_user_agent ~ ^DavClnt ) {
            return 302 /remote.php/webdav/$is_args$args;
        }
    }
    
    location = /robots.txt {
        allow all;
        log_not_found off;
        access_log off;
    }
    
    location ^~ /.well-known {
        location = /.well-known/carddav { return 301 /remote.php/dav/; }
        location = /.well-known/caldav  { return 301 /remote.php/dav/; }
        location /.well-known/acme-challenge    { try_files $uri $uri/ =404; }
        location /.well-known/pki-validation    { try_files $uri $uri/ =404; }
        return 301 /index.php$request_uri;
    }
    
    location ~ ^/(?:build|tests|config|lib|3rdparty|templates|data)(?:$|/)  { return 404; }
    location ~ ^/(?:\.|autotest|occ|issue|indie|db_|console)                { return 404; }
    
    location ~ \.php(?:$|/) {
        rewrite ^/(?!index|remote|public|cron|core\/ajax\/update|status|ocs\/v[12]|updater\/.+|ocs-provider\/.+|.+\/richdocumentscode(_arm64)?\/proxy) /index.php$request_uri;
        
        fastcgi_split_path_info ^(.+?\.php)(/.*)$;
        set $path_info $fastcgi_path_info;
        
        try_files $fastcgi_script_name =404;
        
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param PATH_INFO $path_info;
        fastcgi_param HTTPS on;
        
        fastcgi_param modHeadersAvailable true;
        fastcgi_param front_controller_active true;
        fastcgi_pass php-handler;
        
        fastcgi_intercept_errors on;
        fastcgi_request_buffering off;
        
        fastcgi_max_temp_file_size 0;
        
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }
    
    location ~ \.(?:css|js|svg|gif|png|jpg|ico|wasm|tflite|map|ogg|flac)$ {
        try_files $uri /index.php$request_uri;
        add_header Cache-Control "public, max-age=15778463, $asset_immutable";
        access_log off;
        
        location ~ \.wasm$ {
            default_type application/wasm;
        }
    }
    
    location ~ \.woff2?$ {
        try_files $uri /index.php$request_uri;
        expires 7d;
        access_log off;
    }
    
    location /remote {
        return 301 /remote.php$request_uri;
    }
    
    location / {
        try_files $uri $uri/ /index.php$request_uri;
    }
}
EOF

                sed -i "s|NEXTCLOUD_DOMAIN_PLACEHOLDER|$NEXTCLOUD_DOMAIN|g" "$NGINX_CONF"
                sed -i "s|NEXTCLOUD_DIR_PLACEHOLDER|$NEXTCLOUD_DIR|g" "$NGINX_CONF"
                
                if nginx -t 2>/dev/null; then
                    systemctl reload nginx
                    print_success "NGINX конфигурация обновлена для HTTPS"
                    log_success "NGINX config updated with HTTPS"
                else
                    print_error "Ошибка в HTTPS конфигурации"
                    log_error "NGINX HTTPS config test failed"
                    nginx -t
                    [[ "$FORCE_MODE" != "true" ]] && exit 1
                fi
            else
                print_warning "Не удалось получить SSL сертификат - продолжаем с HTTP"
                log_warning "SSL certificate failed - continuing with HTTP only"
            fi
        else
            print_warning "Certbot не найден - используем HTTP only"
            log_warning "Certbot not found - using HTTP only"
        fi
    fi
fi

# --- Установка NextCloud через occ ---
print_step "Установка NextCloud"
if [[ "$DRY_RUN" == "true" ]]; then
    print_warn "(DRY RUN) php occ maintenance:install"
else
    NEED_INSTALL=false
    
    # Проверяем, установлен ли NextCloud
    if [[ ! -f "$NEXTCLOUD_DIR/config/config.php" ]] || ! grep -q "'installed' => true" "$NEXTCLOUD_DIR/config/config.php"; then
        NEED_INSTALL=true
    else
        # Проверяем соответствие директории данных
        CURRENT_DATA_DIR=$(sudo -u www-data php "$NEXTCLOUD_DIR/occ" config:system:get datadirectory 2>/dev/null || echo "")
        
        if [[ "$CURRENT_DATA_DIR" != "$NEXTCLOUD_DATA_DIR" ]]; then
            print_warning "Директория данных изменилась: $CURRENT_DATA_DIR → $NEXTCLOUD_DATA_DIR"
            print_info "Требуется переустановка NextCloud"
            log_warning "Data directory changed: $CURRENT_DATA_DIR → $NEXTCLOUD_DATA_DIR"
            
            # Создаем резервную копию конфига
            if [[ -f "$NEXTCLOUD_DIR/config/config.php" ]]; then
                cp "$NEXTCLOUD_DIR/config/config.php" "$NEXTCLOUD_DIR/config/config.php.backup.$(date +%Y%m%d_%H%M%S)"
                print_info "Создана резервная копия конфигурации"
            fi
            
            # Удаляем старый конфиг для переустановки
            rm -f "$NEXTCLOUD_DIR/config/config.php"
            NEED_INSTALL=true
        fi
    fi
    
    if [[ "$NEED_INSTALL" == "true" ]]; then
        # Создаем директорию данных если не существует
        mkdir -p "$NEXTCLOUD_DATA_DIR"
        chown -R www-data:www-data "$NEXTCLOUD_DATA_DIR"
        chmod -R 750 "$NEXTCLOUD_DATA_DIR"
        
        # Очищаем БД перед установкой (безопасно как для первой установки, так и для переустановки)
        print_info "Подготовка базы данных..."
        sudo -u postgres psql -c "DROP DATABASE IF EXISTS $NEXTCLOUD_DB_NAME;" >/dev/null 2>&1
        sudo -u postgres psql -c "CREATE DATABASE $NEXTCLOUD_DB_NAME OWNER $NEXTCLOUD_DB_USER;" >/dev/null 2>&1
        sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $NEXTCLOUD_DB_NAME TO $NEXTCLOUD_DB_USER;" >/dev/null 2>&1
        print_success "База данных готова"
        log_info "Database prepared for installation"
        
        sudo -u www-data php "$NEXTCLOUD_DIR/occ" maintenance:install \
            --database "pgsql" \
            --database-name "$NEXTCLOUD_DB_NAME" \
            --database-user "$NEXTCLOUD_DB_USER" \
            --database-pass "$NEXTCLOUD_DB_PASSWORD" \
            --database-host "localhost" \
            --admin-user "$NEXTCLOUD_ADMIN_USER" \
            --admin-pass "$NEXTCLOUD_ADMIN_PASSWORD" \
            --data-dir "$NEXTCLOUD_DATA_DIR" || {
            print_error "Не удалось установить NextCloud"
            log_error "NextCloud installation failed"
            [[ "$FORCE_MODE" != "true" ]] && exit 1
        }
        print_success "NextCloud установлен"
        log_success "NextCloud installed with data directory: $NEXTCLOUD_DATA_DIR"
    else
        print_info "NextCloud уже установлен"
        log_info "NextCloud already installed"
    fi
    
    # Настройка trusted domains
    print_step "Настройка trusted domains"
    sudo -u www-data php "$NEXTCLOUD_DIR/occ" config:system:set trusted_domains 0 --value="$NEXTCLOUD_DOMAIN"
    sudo -u www-data php "$NEXTCLOUD_DIR/occ" config:system:set overwrite.cli.url --value="https://$NEXTCLOUD_DOMAIN"
    
    # Настройка Redis
    sudo -u www-data php "$NEXTCLOUD_DIR/occ" config:system:set memcache.local --value='\OC\Memcache\APCu'
    sudo -u www-data php "$NEXTCLOUD_DIR/occ" config:system:set memcache.locking --value='\OC\Memcache\Redis'
    sudo -u www-data php "$NEXTCLOUD_DIR/occ" config:system:set redis host --value='localhost'
    sudo -u www-data php "$NEXTCLOUD_DIR/occ" config:system:set redis port --value=6379
    
    # Отключение maintenance mode если был включен
    sudo -u www-data php "$NEXTCLOUD_DIR/occ" maintenance:mode --off
    
    print_success "Конфигурация NextCloud завершена"
    log_success "NextCloud configured"
fi

# --- Настройка PHP для NextCloud ---
print_step "Настройка PHP"
if [[ "$DRY_RUN" != "true" ]]; then
    PHP_INI="/etc/php/8.2/fpm/php.ini"
    if [[ -f "$PHP_INI" ]]; then
        sed -i 's/^memory_limit = .*/memory_limit = 512M/' "$PHP_INI"
        sed -i 's/^upload_max_filesize = .*/upload_max_filesize = 10G/' "$PHP_INI"
        sed -i 's/^post_max_size = .*/post_max_size = 10G/' "$PHP_INI"
        sed -i 's/^max_execution_time = .*/max_execution_time = 300/' "$PHP_INI"
        systemctl restart php8.2-fpm
        print_success "PHP настроен"
        log_success "PHP configured"
    fi
fi

# --- Настройка cron ---
print_step "Настройка cron для фоновых задач"
if [[ "$DRY_RUN" != "true" ]]; then
    if ! crontab -u www-data -l 2>/dev/null | grep -q "nextcloud/cron.php"; then
        (crontab -u www-data -l 2>/dev/null; echo "*/5 * * * * php -f $NEXTCLOUD_DIR/cron.php") | crontab -u www-data -
        sudo -u www-data php "$NEXTCLOUD_DIR/occ" background:cron
        print_success "Cron настроен"
        log_success "Cron configured"
    else
        print_info "Cron уже настроен"
        log_info "Cron already configured"
    fi
fi

# --- Проверка установки ---
print_step "Проверка установки"
if [[ "$DRY_RUN" != "true" ]]; then
    if [[ -f "$NEXTCLOUD_DIR/occ" ]]; then
        print_success "NextCloud установлен"
        log_success "NextCloud files present"
    else
        print_error "NextCloud не найден"
        log_error "NextCloud not found"
    fi
    
    if sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw "$NEXTCLOUD_DB_NAME"; then
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
    
    if systemctl is-active --quiet php8.2-fpm; then
        print_success "PHP-FPM работает"
        log_success "PHP-FPM active"
    else
        print_warning "PHP-FPM не работает"
        log_warning "PHP-FPM not active"
    fi
fi

# --- Итоговая информация ---
print_step "Информация о NextCloud"
print_info "URL:          https://$NEXTCLOUD_DOMAIN"
print_info "Логин:        $NEXTCLOUD_ADMIN_USER"
print_info "Пароль:       ********"
print_info "База данных:  $NEXTCLOUD_DB_NAME"
print_info "Данные:       $NEXTCLOUD_DATA_DIR"
print_info ""
print_info "Управление:"
print_info "  sudo -u www-data php $NEXTCLOUD_DIR/occ"
print_info "  sudo -u www-data php $NEXTCLOUD_DIR/occ user:list"
print_info "  sudo -u www-data php $NEXTCLOUD_DIR/occ app:list"
print_info ""
print_info "Добавить пользователя:"
print_info "  sudo -u www-data php $NEXTCLOUD_DIR/occ user:add --password-from-env username"
print_info "  (затем ввести пароль)"

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "NextCloud настроен:"
log_info "  URL: https://$NEXTCLOUD_DOMAIN"
log_info "  Admin: $NEXTCLOUD_ADMIN_USER"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

print_success "✅ Модуль облачного хранилища (NextCloud) завершён"
log_info "Модуль 19-cloud-nextcloud.sh завершён успешно"