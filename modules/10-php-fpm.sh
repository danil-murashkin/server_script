#!/bin/bash
# modules/10-php-fpm.sh - Установка и настройка PHP-FPM
# Часть Mail Server Deployment Module System

# --- Загрузка вспомогательных утилит ---
[[ -z "${UTIL_PRINT_LOADED}" ]] && source ./utils/print.sh 2>/dev/null
[[ -z "${UTIL_LOGGING_LOADED}" ]] && source ./utils/logging.sh 2>/dev/null
[[ -z "${UTIL_FUNCTIONS_LOADED}" ]] && source ./utils/functions.sh 2>/dev/null

# --- Проверка прав root ---
ensure_root

# --- Загружаем конфиг, если нужно ---
load_config || {
    print_error "Не удалось загрузить конфигурацию. Убедитесь, что ./config/main.conf существует."
    log_error "Failed to load required configuration"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
}

# --- Проверка ОС ---
ensure_debian || {
    print_error "Поддерживается только Debian 11+"
    log_error "Unsupported OS. Only Debian 11+ is supported."
    [[ "$FORCE_MODE" != "true" ]] && exit 1
}

# --- Проверка наличия необходимых команд ---
require_command "curl" "загрузка репозиториев"
require_command "wget" "загрузка ключей"

# --- Добавление репозитория PHP (deb.sury.org) ---
print_step "Добавление репозитория PHP 8.2"
if ! apt-cache policy php8.2-fpm | grep -q "Installed:"; then
    # Установка зависимостей для добавления репозитория
    if ! apt install -y ca-certificates apt-transport-https software-properties-common > /dev/null 2>&1; then
        print_error "Не удалось установить зависимости для репозитория"
        log_error "Failed to install repository dependencies"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi

    # Импорт GPG-ключа
    print_step "Импорт GPG-ключа репозитория PHP"
    curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /etc/apt/trusted.gpg.d/php.gpg > /dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        print_error "Не удалось импортировать GPG-ключ PHP"
        log_error "Failed to import PHP GPG key"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi

    # Добавление репозитория
    print_step "Добавление репозитория в sources.list.d"
    echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list
    if [[ $? -ne 0 ]]; then
        print_error "Не удалось добавить репозиторий PHP"
        log_error "Failed to add PHP repository"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi

    # Обновление списка пакетов
    print_step "Обновление списка пакетов"
    if ! apt update -qq > /dev/null 2>&1; then
        print_error "Не удалось обновить список пакетов"
        log_error "Failed to update package list"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
else
    print_info "Репозиторий PHP уже настроен — пропуск"
    log_info "PHP repository already configured — skipping"
fi

# --- Установка PHP и расширений ---
print_step "Установка PHP 8.2 и расширений"

PHP_PACKAGES=(
    php8.2-fpm
    php8.2-pgsql
    php8.2-mysql
    php8.2-common
    php8.2-curl
    php8.2-mbstring
    php8.2-xmlrpc
    php8.2-gd
    php8.2-xml
    php8.2-intl
    php8.2-ldap
    php8.2-imagick
    php8.2-cli
    php8.2-zip
    php8.2-dom
    php8.2-simplexml
    php8.2-redis
    php8.2-apcu
    php8.2-bz2
    php8.2-gmp
    php8.2-opcache
    php8.2-memcached
    php8.2-ftp
    php8.2-bcmath
    php8.2-imap
    php8.2-sqlite3
    php8.2-pspell
    php8.2-enchant
)

if ! dpkg -l | grep -q "php8.2-fpm"; then
    if apt install -y "${PHP_PACKAGES[@]}" > /dev/null 2>&1; then
        print_success "PHP 8.2 и все расширения успешно установлены"
        log_info "PHP 8.2 and all extensions installed successfully"
    else
        print_error "Не удалось установить PHP 8.2"
        log_error "Failed to install PHP 8.2"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
else
    print_success "PHP 8.2 уже установлен — обновление пакетов"
    log_info "PHP 8.2 is already installed — updating packages"
    if apt install -y --only-upgrade "${PHP_PACKAGES[@]}" > /dev/null 2>&1; then
        print_success "Пакеты PHP обновлены"
        log_info "PHP packages upgraded"
    else
        print_warning "Не удалось обновить пакеты PHP — продолжаем"
        log_warn "Failed to upgrade PHP packages — continuing"
    fi
fi

# --- Установка Composer ---
print_step "Установка Composer (менеджер зависимостей PHP)"
if ! command -v composer &> /dev/null; then
    print_info "Скачивание и установка Composer..."
    
    # Переходим в временную директорию
    cd /tmp
    
    # Скачиваем установщик Composer
    if curl -sS https://getcomposer.org/installer -o composer-setup.php; then
        # Проверяем целостность установщика (опционально)
        EXPECTED_CHECKSUM="$(curl -sS https://composer.github.io/installer.sig)"
        ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"
        
        if [[ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]]; then
            print_warning "Checksum установщика Composer не совпадает — продолжаем без проверки"
            log_warn "Composer installer checksum mismatch — continuing without verification"
        fi
        
        # Устанавливаем Composer
        if php composer-setup.php --quiet && mv composer.phar /usr/local/bin/composer; then
            chmod +x /usr/local/bin/composer
            rm -f composer-setup.php
            print_success "Composer установлен"
            log_info "Composer installed successfully"
            
            # Проверяем версию
            COMPOSER_VERSION=$(composer --version 2>/dev/null | head -n 1 | cut -d' ' -f3)
            print_info "Версия Composer: $COMPOSER_VERSION"
            log_info "Composer version: $COMPOSER_VERSION"
        else
            print_error "Не удалось установить Composer"
            log_error "Failed to install Composer"
            rm -f composer-setup.php composer.phar 2>/dev/null
            [[ "$FORCE_MODE" != "true" ]] && exit 1
        fi
    else
        print_error "Не удалось скачать установщик Composer"
        log_error "Failed to download Composer installer"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
else
    print_success "Composer уже установлен"
    COMPOSER_VERSION=$(composer --version 2>/dev/null | head -n 1 | cut -d' ' -f3)
    print_info "Версия Composer: $COMPOSER_VERSION"
    log_info "Composer already installed. Version: $COMPOSER_VERSION"
    
    # Обновляем Composer до последней версии
    print_info "Обновление Composer до последней версии..."
    if composer self-update --quiet > /dev/null 2>&1; then
        NEW_VERSION=$(composer --version 2>/dev/null | head -n 1 | cut -d' ' -f3)
        if [[ "$NEW_VERSION" != "$COMPOSER_VERSION" ]]; then
            print_success "Composer обновлен до версии: $NEW_VERSION"
            log_info "Composer updated to version: $NEW_VERSION"
        else
            print_info "Composer уже последней версии"
            log_info "Composer already up to date"
        fi
    else
        print_warning "Не удалось обновить Composer — продолжаем"
        log_warn "Failed to update Composer — continuing"
    fi
fi

# --- Настройка php.ini (production) ---
print_step "Настройка php.ini для production-среды"

PHP_INI_PATH="/etc/php/8.2/fpm/php.ini"

if [[ -f "$PHP_INI_PATH" ]]; then
    # Создаём резервную копию
    cp "$PHP_INI_PATH" "$PHP_INI_PATH.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null && \
        log_info "Backup of php.ini created"

    # Функция для безопасной замены значений в php.ini
    set_php_ini_value() {
        local key="$1"
        local value="$2"
        # Экранируем символы для sed
        local escaped_value=$(echo "$value" | sed 's/[\/&]/\\&/g')
        # Заменяем значение, если ключ существует
        if grep -q "^;*\s*$key\s*=" "$PHP_INI_PATH"; then
            sed -i "s|^\(;*\s*$key\s*=\s*\).*|\1$escaped_value|" "$PHP_INI_PATH"
        else
            # Если ключа нет — добавляем в конец файла
            echo "$key = $value" >> "$PHP_INI_PATH"
        fi
    }

    # Основные настройки для production
    set_php_ini_value "max_execution_time" "300"
    set_php_ini_value "memory_limit" "2G"
    set_php_ini_value "post_max_size" "128M"
    set_php_ini_value "upload_max_filesize" "128M"
    set_php_ini_value "max_input_vars" "5000"
    set_php_ini_value "date.timezone" "Europe/Moscow"
    set_php_ini_value "display_errors" "Off"
    set_php_ini_value "log_errors" "On"
    set_php_ini_value "error_log" "/var/log/php_errors.log"
    set_php_ini_value "opcache.enable" "1"
    set_php_ini_value "opcache.memory_consumption" "128"
    set_php_ini_value "opcache.max_accelerated_files" "4000"
    set_php_ini_value "opcache.revalidate_freq" "60"

    print_success "php.ini настроен для production"
    log_info "php.ini configured for production environment"
else
    print_error "Файл php.ini не найден: $PHP_INI_PATH"
    log_error "php.ini file not found: $PHP_INI_PATH"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# --- Создание лог-файла для PHP и установка прав ---
safe_mkdir "/var/log/php" "www-data:www-data" "755"
touch /var/log/php_errors.log
chown www-data:www-data /var/log/php_errors.log
chmod 644 /var/log/php_errors.log

# --- Настройка пула PHP-FPM (www.conf) ---
print_step "Настройка пула PHP-FPM (www.conf)"

PHP_FPM_CONF="/etc/php/8.2/fpm/pool.d/www.conf"

if [[ -f "$PHP_FPM_CONF" ]]; then
    cp "$PHP_FPM_CONF" "$PHP_FPM_CONF.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null && \
        log_info "Backup of www.conf created"

    # Настройка параметров пула
    sed -i 's/;*user = .*/user = www-data/' "$PHP_FPM_CONF"
    sed -i 's/;*group = .*/group = www-data/' "$PHP_FPM_CONF"
    sed -i 's/;*listen.owner = .*/listen.owner = www-data/' "$PHP_FPM_CONF"
    sed -i 's/;*listen.group = .*/listen.group = www-data/' "$PHP_FPM_CONF"
    sed -i 's/;*listen.mode = .*/listen.mode = 0660/' "$PHP_FPM_CONF"

    # Настройка процессов
    sed -i 's/;*pm = .*/pm = dynamic/' "$PHP_FPM_CONF"
    sed -i 's/;*pm.max_children = .*/pm.max_children = 50/' "$PHP_FPM_CONF"
    sed -i 's/;*pm.start_servers = .*/pm.start_servers = 5/' "$PHP_FPM_CONF"
    sed -i 's/;*pm.min_spare_servers = .*/pm.min_spare_servers = 5/' "$PHP_FPM_CONF"
    sed -i 's/;*pm.max_spare_servers = .*/pm.max_spare_servers = 35/' "$PHP_FPM_CONF"

    # Включение медленного лога (slow log)
    sed -i 's/;*slowlog = .*/slowlog = \/var\/log\/php\/\$pool.log.slow/' "$PHP_FPM_CONF"
    sed -i 's/;*request_slowlog_timeout = .*/request_slowlog_timeout = 5s/' "$PHP_FPM_CONF"

    print_success "Пул PHP-FPM настроен"
    log_info "PHP-FPM pool configured"
else
    print_error "Файл www.conf не найден: $PHP_FPM_CONF"
    log_error "www.conf file not found: $PHP_FPM_CONF"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# --- Перезапуск PHP-FPM ---
print_step "Перезапуск службы PHP-FPM"
if systemctl restart php8.2-fpm > /dev/null 2>&1 && systemctl enable php8.2-fpm > /dev/null 2>&1; then
    print_success "Служба PHP-FPM перезапущена и включена в автозагрузку"
    log_info "PHP-FPM service restarted and enabled"
else
    print_error "Не удалось перезапустить PHP-FPM"
    log_error "Failed to restart PHP-FPM service"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# --- Проверка статуса службы ---
if systemctl is-active --quiet php8.2-fpm; then
    print_success "Служба PHP-FPM активна"
    log_info "PHP-FPM service is active"
else
    print_error "Служба PHP-FPM не запущена"
    log_error "PHP-FPM service is not active"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# --- Создание тестового PHP-файла ---
print_step "Создание тестового файла info.php"

TEST_PHP_FILE="/var/www/$DOMAIN/info.php"

if [[ -n "$DOMAIN" ]] && [[ -d "/var/www/$DOMAIN" ]]; then
    cat > "$TEST_PHP_FILE" <<'EOF'
<?php
phpinfo();
?>
EOF

    chown www-data:www-data "$TEST_PHP_FILE"
    chmod 644 "$TEST_PHP_FILE"

    print_success "Тестовый файл создан: http://$DOMAIN/info.php"
    log_info "Test file created: $TEST_PHP_FILE"
else
    print_warning "Домен не настроен или директория сайта не существует — пропуск создания info.php"
    log_warn "Domain not configured or site directory does not exist — skipping info.php"
fi

# --- Интеграция с NGINX (если сайт настроен) ---
if [[ -n "$DOMAIN" ]] && [[ -f "/etc/nginx/sites-available/$DOMAIN" ]]; then
    print_step "Настройка NGINX для обработки PHP-файлов"

    # Добавляем обработку .php в конфиг сайта
    if ! grep -q "location ~ \.php\$" "/etc/nginx/sites-available/$DOMAIN"; then
        # Создаём резервную копию
        cp "/etc/nginx/sites-available/$DOMAIN" "/etc/nginx/sites-available/$DOMAIN.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null

        # Вставляем блок обработки PHP перед закрывающей скобкой server
        sed -i '/^}/i\
    # PHP-FPM\
    location ~ \.php$ {\
        include snippets/fastcgi-php.conf;\
        fastcgi_pass unix:/run/php/php8.2-fpm.sock;\
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;\
        include fastcgi_params;\
    }\
\
    # Запрещаем доступ к .htaccess\
    location ~ /\.ht {\
        deny all;\
    }' "/etc/nginx/sites-available/$DOMAIN"

        print_success "Конфигурация NGINX обновлена для PHP"
        log_info "NGINX configuration updated for PHP processing"
    else
        print_info "Обработка PHP уже настроена в NGINX — пропуск"
        log_info "PHP processing already configured in NGINX — skipping"
    fi

    # Проверка конфигурации NGINX
    print_step "Проверка конфигурации NGINX"
    if nginx -t > /dev/null 2>&1; then
        print_success "Конфигурация NGINX корректна"
        log_info "NGINX configuration test passed"

        # Перезагрузка NGINX
        print_step "Перезагрузка NGINX"
        if systemctl reload nginx > /dev/null 2>&1; then
            print_success "NGINX перезагружен"
            log_info "NGINX reloaded"
        else
            print_error "Не удалось перезагрузить NGINX"
            log_error "Failed to reload NGINX"
            [[ "$FORCE_MODE" != "true" ]] && exit 1
        fi
    else
        print_error "Ошибки в конфигурации NGINX"
        log_error "NGINX configuration test failed"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
else
    print_warning "NGINX не настроен для домена $DOMAIN — пропуск интеграции"
    log_warn "NGINX not configured for domain $DOMAIN — skipping integration"
fi

# --- Проверка работы PHP ---
print_step "Проверка работы PHP через CLI"
if php -v > /dev/null 2>&1; then
    PHP_VERSION=$(php -v | head -n 1 | cut -d' ' -f2)
    print_success "PHP CLI работает. Версия: $PHP_VERSION"
    log_info "PHP CLI is working. Version: $PHP_VERSION"
else
    print_error "PHP CLI не работает"
    log_error "PHP CLI is not working"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# --- Информация для пользователя ---
print_section "🐘 ИНФОРМАЦИЯ О PHP"

print_success "✅ PHP 8.2 успешно установлен и настроен"
print_info "Версия PHP: $(php -v | head -n 1 | cut -d' ' -f2)"
if command -v composer &> /dev/null; then
    print_info "Версия Composer: $(composer --version 2>/dev/null | head -n 1 | cut -d' ' -f3)"
fi
print_info "Конфигурационные файлы:"
print_info "   • php.ini: $PHP_INI_PATH"
print_info "   • www.conf: $PHP_FPM_CONF"
print_info ""
print_info "Служба:"
print_info "   • systemctl status php8.2-fpm"
print_info "   • systemctl restart php8.2-fpm"
print_info ""
if [[ -n "$DOMAIN" ]] && [[ -d "/var/www/$DOMAIN" ]]; then
    print_info "Тестовый файл:"
    print_info "   • http://$DOMAIN/info.php"
fi
print_info ""
print_info "Команды:"
print_info "   • php -v (версия PHP)"
print_info "   • composer --version (версия Composer)"
print_info "   • php -m | grep -E '(pdo_pgsql|gd|opcache|redis|ldap)'"

log_info "PHP 8.2 and Composer setup completed"
