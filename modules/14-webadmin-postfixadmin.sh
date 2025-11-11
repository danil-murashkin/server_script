#!/bin/bash
# modules/14-webadmin-postfixadmin.sh - Установка и настройка PostfixAdmin
# Часть Mail Server Deployment Module System

# --- Загрузка вспомогательных утилит ---
[[ -z "${UTIL_PRINT_LOADED}" ]] && source ./utils/print.sh 2>/dev/null
[[ -z "${UTIL_LOGGING_LOADED}" ]] && source ./utils/logging.sh 2>/dev/null
[[ -z "${UTIL_FUNCTIONS_LOADED}" ]] && source ./utils/functions.sh 2>/dev/null

# --- Проверка прав root ---
ensure_root

# --- Загружаем конфиг, если нужно ---
load_config || {
    print_error "Не удалось загрузить конфигурацию. Убедитесь, что ./config/main.conf существует и содержит DOMAIN, SERVER_IP, ADMIN_EMAIL, ADMIN_PASSWORD."
    log_error "Failed to load required configuration"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
}

# --- Проверка переменных ---
print_step "Проверка необходимых переменных: DOMAIN, SERVER_IP, ADMIN_EMAIL, ADMIN_PASSWORD"
for var in DOMAIN SERVER_IP ADMIN_EMAIL ADMIN_PASSWORD; do
    if [[ -z "${!var}" ]]; then
        print_error "Переменная $var не задана"
        log_error "$var is not set"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
done

# Используем ADMIN_USER если задан, иначе по умолчанию webadmin
ADMIN_USER="${ADMIN_USER:-webadmin}"
print_info "Пользователь БД: $ADMIN_USER"
log_info "Database user: $ADMIN_USER"

# --- Проверка ОС ---
ensure_debian || {
    print_error "Поддерживается только Debian 11+"
    log_error "Unsupported OS. Only Debian 11+ is supported."
    [[ "$FORCE_MODE" != "true" ]] && exit 1
}

# --- Проверка наличия зависимостей ---
if ! systemctl is-active --quiet nginx; then
    print_error "NGINX не запущен. Установите и настройте модуль 08-web-server.sh перед этим."
    log_error "NGINX is not active. Install 08-web-server.sh first."
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

if ! systemctl is-active --quiet php8.2-fpm; then
    print_error "PHP-FPM не запущен. Установите и настройте модуль 10-php-fpm.sh перед этим."
    log_error "PHP-FPM is not active. Install 10-php-fpm.sh first."
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

if ! systemctl is-active --quiet postgresql; then
    print_error "PostgreSQL не запущен. Установите и настройте модуль 09-database.sh перед этим."
    log_error "PostgreSQL is not active. Install 09-database.sh first."
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# --- Проверка PHP-расширений ---
print_step "Проверка PHP-расширений"
MISSING_EXTENSIONS=()
for ext in intl mbstring xml pgsql; do
    if ! php -m | grep -qi "^$ext$"; then
        MISSING_EXTENSIONS+=("$ext")
    fi
done
if [[ ${#MISSING_EXTENSIONS[@]} -gt 0 ]]; then
    print_error "Отсутствуют PHP-расширения: ${MISSING_EXTENSIONS[*]}"
    log_error "Missing PHP extensions: ${MISSING_EXTENSIONS[*]}"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
else
    print_success "Все необходимые PHP-расширения найдены"
    log_info "All required PHP extensions found"
fi

# --- Проверка наличия команд ---
print_step "Проверка необходимых зависимостей"
for cmd in git composer curl; do
    if ! command -v "$cmd" &> /dev/null; then
        print_error "Команда $cmd не найдена. Установите модуль 10-php-fpm.sh перед этим."
        log_error "Command $cmd not found. Install 10-php-fpm.sh first."
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
done
print_success "Все необходимые команды найдены"
log_info "All required commands found"

# --- Создание директории для PostfixAdmin ---
POSTFIXADMIN_SUBDOMAIN="mailadmin"
POSTFIXADMIN_DOMAIN="$POSTFIXADMIN_SUBDOMAIN.$DOMAIN"
POSTFIXADMIN_DIR="/var/www/$POSTFIXADMIN_DOMAIN"
print_step "Создание директории для PostfixAdmin: $POSTFIXADMIN_DIR"
safe_mkdir "$POSTFIXADMIN_DIR" "www-data:www-data" "755" || {
    print_error "Не удалось создать директорию PostfixAdmin"
    log_error "Failed to create PostfixAdmin directory"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
}

# --- Скачивание PostfixAdmin ---
print_step "Скачивание PostfixAdmin (последняя стабильная версия)"
cd "$POSTFIXADMIN_DIR"
if [[ ! -f "public/index.php" ]]; then
    # Очищаем директорию, если она не пустая (кроме скрытых файлов)
    if [[ -n "$(ls -A . 2>/dev/null | grep -v '^\.')" ]]; then
        print_info "Очистка существующей директории..."
        rm -rf ./* 2>/dev/null || true
    fi
    
    # Клонируем репозиторий
    print_info "Клонирование репозитория PostfixAdmin..."
    if git clone --depth 1 https://github.com/postfixadmin/postfixadmin.git . > /dev/null 2>&1; then
        print_success "PostfixAdmin скачан"
        log_info "PostfixAdmin downloaded"
    else
        print_error "Не удалось скачать PostfixAdmin"
        log_error "Failed to download PostfixAdmin"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
else
    print_info "PostfixAdmin уже скачан — пропуск"
    log_info "PostfixAdmin already downloaded — skipping"
fi

# --- Проверка зависимостей через Composer ---
print_step "Проверка PHP-зависимостей через Composer"
if [[ ! -d "vendor" ]]; then
    print_info "Устанавливаем зависимости Composer..."
    # Запускаем composer с подавлением deprecation warnings
    export COMPOSER_ALLOW_SUPERUSER=1
    export COMPOSER_NO_INTERACTION=1
    if composer install --no-dev --optimize-autoloader --quiet 2>/dev/null; then
        print_success "Зависимости установлены"
        log_info "PHP dependencies installed"
    else
        print_warning "Composer install с предупреждениями, повторяем с debug..."
        if composer install --no-dev --optimize-autoloader --verbose; then
            print_success "Зависимости установлены (с предупреждениями)"
            log_info "PHP dependencies installed with warnings"
        else
            print_error "Не удалось установить зависимости через Composer"
            log_error "Failed to install dependencies via Composer"
            [[ "$FORCE_MODE" != "true" ]] && exit 1
        fi
    fi
else
    print_success "Зависимости Composer уже установлены"
    log_info "Dependencies already installed — skipping"
fi

# --- Настройка config.local.php ---
print_step "Настройка config.local.php"
CONFIG_FILE="$POSTFIXADMIN_DIR/config.local.php"
# Генерируем setup_password заранее
SETUP_PASSWORD=$(openssl rand -base64 32)
if [[ ! -f "$CONFIG_FILE" ]]; then
    cat > "$CONFIG_FILE" <<EOF
<?php
\$CONF['configured'] = true;
\$CONF['setup_password'] = '$SETUP_PASSWORD';
\$CONF['database_type'] = 'pgsql';
\$CONF['database_host'] = 'localhost';
\$CONF['database_user'] = '$ADMIN_USER';
\$CONF['database_password'] = '$ADMIN_PASSWORD';
\$CONF['database_name'] = '${DOMAIN//./_}';
\$CONF['encrypt'] = 'md5crypt';
\$CONF['dovecotpw'] = "/usr/bin/doveadm pw";
\$CONF['domain_path'] = 'NO';
\$CONF['domain_in_mailbox'] = 'YES';
\$CONF['fetchmail'] = 'NO';
\$CONF['sendmail'] = '/usr/sbin/sendmail';
\$CONF['smtp_server'] = 'localhost';
\$CONF['smtp_port'] = '25';
\$CONF['admin_email'] = '$ADMIN_EMAIL';
\$CONF['default_aliases'] = array(
    'abuse' => 'abuse@$DOMAIN',
    'hostmaster' => 'hostmaster@$DOMAIN',
    'postmaster' => 'postmaster@$DOMAIN',
    'webmaster' => 'webmaster@$DOMAIN'
);
\$CONF['quota'] = 'NO';
\$CONF['aliases'] = '0';
\$CONF['mailboxes'] = '0';
\$CONF['maxquota'] = '0';
\$CONF['domain_quota_default'] = '0';
\$CONF['vacation'] = 'NO';
\$CONF['show_header_text'] = 'NO';
\$CONF['header_text'] = ':: Postfix Admin ::';
\$CONF['show_footer_text'] = 'YES';
\$CONF['footer_text'] = 'Return to $DOMAIN';
\$CONF['welcome_text'] = <<<EOM
Hi,
Welcome to your new account!
EOM;
\$CONF['emailcheck_resolve_domain']='YES';
\$CONF['show_status']='YES';
\$CONF['show_status_host']='localhost';
\$CONF['session_key'] = '$(openssl rand -base64 32 | tr -d '\n' | tr -d '/' | tr -d '+')';
\$CONF['page_size'] = '10';
\$CONF['theme_logo'] = 'images/logo-postfixadmin.png';
\$CONF['theme_css'] = 'css/default.css';
?>
EOF
    if [[ $? -eq 0 ]]; then
        print_success "config.local.php настроен"
        log_info "config.local.php configured"
        # Выводим setup_password для администратора
        print_warning "СОХРАНИТЕ setup_password для первого входа:"
        print_color "BRIGHT_WHITE" "   $SETUP_PASSWORD"
        log_info "PostfixAdmin setup_password: $SETUP_PASSWORD"
    else
        print_error "Не удалось создать config.local.php"
        log_error "Failed to create config.local.php"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
else
    print_info "config.local.php уже существует — пропуск"
    log_info "config.local.php already exists — skipping"
fi

# --- Установка прав ---
print_step "Установка прав на файлы PostfixAdmin"
chown -R www-data:www-data "$POSTFIXADMIN_DIR"
chmod -R 755 "$POSTFIXADMIN_DIR"
chmod 644 "$CONFIG_FILE"

# Создание необходимых директорий для Smarty
print_info "Создание директорий для шаблонов Smarty..."
mkdir -p "$POSTFIXADMIN_DIR/templates_c"
mkdir -p "$POSTFIXADMIN_DIR/cache"
chown www-data:www-data "$POSTFIXADMIN_DIR/templates_c" "$POSTFIXADMIN_DIR/cache"
chmod 755 "$POSTFIXADMIN_DIR/templates_c" "$POSTFIXADMIN_DIR/cache"
print_success "Права на файлы PostfixAdmin установлены"
log_info "Permissions for PostfixAdmin files set"

# --- Проверка подключения к базе данных ---
print_step "Проверка подключения к базе данных PostgreSQL"
DB_NAME="${DOMAIN//./_}"
# Проверяем подключение с учетными данными из конфига
if ! PGPASSWORD="$ADMIN_PASSWORD" psql -h localhost -U "$ADMIN_USER" -d "$DB_NAME" -c "\q" 2>/dev/null; then
    print_error "Не удается подключиться к базе данных $DB_NAME как пользователь $ADMIN_USER"
    print_info "Проверьте настройки PostgreSQL и права доступа"
    log_error "Cannot connect to database $DB_NAME as user $ADMIN_USER"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
else
    print_success "Подключение к базе данных успешно"
    log_info "Database connection successful"
fi

# --- Инициализация базы данных ---
print_step "Инициализация базы данных PostfixAdmin"
if [[ ! -f "$POSTFIXADMIN_DIR/DATABASE_INITIALIZED" ]]; then
    cd "$POSTFIXADMIN_DIR"
    # Устанавливаем переменные окружения для подключения к БД
    export PGPASSWORD="$ADMIN_PASSWORD"
    export PGUSER="$ADMIN_USER"
    export PGHOST="localhost"
    export PGDATABASE="$DB_NAME"
    print_info "Инициализация схемы базы данных..."

    # Проверяем, существует ли хотя бы одна основная таблица
    admin_table_check=$(psql -h localhost -U "$ADMIN_USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_name='admin';" 2>/dev/null | tr -d ' ')
    config_table_check=$(psql -h localhost -U "$ADMIN_USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_name='config';" 2>/dev/null | tr -d ' ')

    if [[ "$admin_table_check" == "0" ]] && [[ "$config_table_check" == "0" ]]; then
        # Полная инициализация — ни одной таблицы нет
        print_info "Создание полной схемы PostfixAdmin..."
        # Пытаемся найти SQL файл для создания таблиц
        sql_files=(
            "DOCUMENTS/database_pgsql.sql"
            "sql/pgsql.sql" 
            "DATABASE_PGSQL.txt"
            "docs/DATABASE_PGSQL.txt"
            "DOCUMENTS/DATABASE_PGSQL.txt"
        )
        sql_found=false
        for sql_file in "${sql_files[@]}"; do
            if [[ -f "$sql_file" ]]; then
                print_info "Найден SQL файл: $sql_file"
                if psql -h localhost -U "$ADMIN_USER" -d "$DB_NAME" -f "$sql_file" >/dev/null 2>&1; then
                    print_success "Схема базы данных создана из $sql_file"
                    sql_found=true
                    break
                else
                    print_warning "Не удалось выполнить $sql_file"
                fi
            fi
        done
        # Если SQL файл не найден, создаем полную схему вручную
        if [[ "$sql_found" == "false" ]]; then
            print_info "Создание полной схемы PostfixAdmin вручную..."
            # Создаём полную схему PostfixAdmin
            psql -h localhost -U "$ADMIN_USER" -d "$DB_NAME" <<-'FULLSQL' >/dev/null 2>&1
-- Полная схема PostfixAdmin для PostgreSQL
CREATE TABLE IF NOT EXISTS admin (
    username varchar(255) NOT NULL DEFAULT '',
    password varchar(255) NOT NULL DEFAULT '',
    superadmin boolean NOT NULL DEFAULT false,
    created timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    modified timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    active boolean NOT NULL DEFAULT true,
    PRIMARY KEY (username)
);
CREATE TABLE IF NOT EXISTS domain (
    domain varchar(255) NOT NULL DEFAULT '',
    description varchar(255) NOT NULL DEFAULT '',
    aliases int NOT NULL DEFAULT 0,
    mailboxes int NOT NULL DEFAULT 0,
    maxquota bigint NOT NULL DEFAULT 0,
    quota bigint NOT NULL DEFAULT 0,
    transport varchar(255) NOT NULL DEFAULT '',
    backupmx boolean NOT NULL DEFAULT false,
    created timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    modified timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    active boolean NOT NULL DEFAULT true,
    defaultaliases boolean NOT NULL DEFAULT true,
    password_expiry integer NOT NULL DEFAULT 0,
    PRIMARY KEY (domain)
);
CREATE TABLE IF NOT EXISTS mailbox (
    username varchar(255) NOT NULL DEFAULT '',
    password varchar(255) NOT NULL DEFAULT '',
    name varchar(255) NOT NULL DEFAULT '',
    maildir varchar(255) NOT NULL DEFAULT '',
    quota bigint NOT NULL DEFAULT 0,
    local_part varchar(255) NOT NULL DEFAULT '',
    domain varchar(255) NOT NULL DEFAULT '',
    created timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    modified timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    active boolean NOT NULL DEFAULT true,
    phone varchar(20) NOT NULL DEFAULT '',
    email_other varchar(255) NOT NULL DEFAULT '',
    token varchar(255) NOT NULL DEFAULT '',
    token_validity timestamp NOT NULL DEFAULT '1999-12-31 23:59:59',
    password_expiry timestamp,
    smtp_active boolean NOT NULL DEFAULT true,
    pop3_active boolean NOT NULL DEFAULT true,
    imap_active boolean NOT NULL DEFAULT true,
    sieve_active boolean NOT NULL DEFAULT true,
    PRIMARY KEY (username)
);
CREATE TABLE IF NOT EXISTS alias (
    address varchar(255) NOT NULL DEFAULT '',
    goto text NOT NULL,
    domain varchar(255) NOT NULL DEFAULT '',
    created timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    modified timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    active boolean NOT NULL DEFAULT true,
    PRIMARY KEY (address)
);
CREATE TABLE IF NOT EXISTS alias_domain (
    alias_domain varchar(255) NOT NULL DEFAULT '',
    target_domain varchar(255) NOT NULL DEFAULT '',
    created timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    modified timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    active boolean NOT NULL DEFAULT true,
    PRIMARY KEY (alias_domain)
);
CREATE TABLE IF NOT EXISTS config (
    id serial,
    name varchar(20) NOT NULL DEFAULT '',
    value varchar(20) NOT NULL DEFAULT '',
    PRIMARY KEY (id)
);
CREATE TABLE IF NOT EXISTS domain_admins (
    username varchar(255) NOT NULL DEFAULT '',
    domain varchar(255) NOT NULL DEFAULT '',
    created timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    active boolean NOT NULL DEFAULT true
);
CREATE TABLE IF NOT EXISTS fetchmail (
    id serial,
    mailbox varchar(255) NOT NULL DEFAULT '',
    src_server varchar(255) NOT NULL DEFAULT '',
    src_auth varchar(15) NOT NULL DEFAULT 'password',
    src_user varchar(255) NOT NULL DEFAULT '',
    src_password varchar(255) NOT NULL DEFAULT '',
    src_folder varchar(255) NOT NULL DEFAULT 'INBOX',
    poll_time int NOT NULL DEFAULT 10,
    fetchall boolean NOT NULL DEFAULT false,
    keep boolean NOT NULL DEFAULT false,
    protocol varchar(15) NOT NULL DEFAULT 'POP3',
    usessl boolean NOT NULL DEFAULT false,
    extra_options text,
    returned_text text,
    mda varchar(255) NOT NULL DEFAULT '',
    date timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id)
);
CREATE TABLE IF NOT EXISTS log (
    timestamp timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    username varchar(255) NOT NULL DEFAULT '',
    domain varchar(255) NOT NULL DEFAULT '',
    action varchar(255) NOT NULL DEFAULT '',
    data text NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS quota (
    username varchar(255) NOT NULL,
    path varchar(100) NOT NULL,
    current bigint DEFAULT 0,
    PRIMARY KEY (username,path)
);
CREATE TABLE IF NOT EXISTS quota2 (
    username varchar(100) NOT NULL,
    bytes bigint NOT NULL DEFAULT 0,
    messages int NOT NULL DEFAULT 0,
    PRIMARY KEY (username)
);
CREATE TABLE IF NOT EXISTS vacation (
    email varchar(255) NOT NULL DEFAULT '',
    subject varchar(255) NOT NULL DEFAULT '',
    body text NOT NULL DEFAULT '',
    cache text NOT NULL DEFAULT '',
    domain varchar(255) NOT NULL DEFAULT '',
    created timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    active boolean NOT NULL DEFAULT true,
    interval_time int NOT NULL DEFAULT 0,
    activefrom timestamp NOT NULL DEFAULT '1999-12-31 23:59:59',
    activeuntil timestamp NOT NULL DEFAULT '1999-12-31 23:59:59',
    PRIMARY KEY (email)
);
CREATE TABLE IF NOT EXISTS vacation_notification (
    on_vacation varchar(255) NOT NULL,
    notified varchar(255) NOT NULL,
    notified_at timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (on_vacation,notified)
);
CREATE TABLE IF NOT EXISTS alias_domain (
    alias_domain varchar(255) NOT NULL DEFAULT '',
    target_domain varchar(255) NOT NULL DEFAULT '',
    created timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    modified timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    active boolean NOT NULL DEFAULT true,
    PRIMARY KEY (alias_domain)
);
-- Вставляем версию конфигурации
INSERT INTO config (name, value) VALUES ('version', '1840') ON CONFLICT DO NOTHING;
FULLSQL
            if [[ $? -eq 0 ]]; then
                print_success "Полная схема PostfixAdmin создана"
                sql_found=true
            else
                print_error "Не удалось создать схему базы данных"
                log_error "Failed to create database schema"
                [[ "$FORCE_MODE" != "true" ]] && exit 1
            fi
        fi
    elif [[ "$admin_table_check" == "0" ]] || [[ "$config_table_check" == "0" ]]; then
        # Частичная инициализация — дополняем недостающие таблицы
        print_info "Дополнение существующей схемы недостающими таблицами..."
        psql -h localhost -U "$ADMIN_USER" -d "$DB_NAME" <<-'ADDTABLES' >/dev/null 2>&1
-- Добавляем недостающие таблицы
CREATE TABLE IF NOT EXISTS admin (
    username varchar(255) NOT NULL DEFAULT '',
    password varchar(255) NOT NULL DEFAULT '',
    superadmin boolean NOT NULL DEFAULT false,
    created timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    modified timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    active boolean NOT NULL DEFAULT true,
    PRIMARY KEY (username)
);
CREATE TABLE IF NOT EXISTS config (
    id serial,
    name varchar(20) NOT NULL DEFAULT '',
    value varchar(20) NOT NULL DEFAULT '',
    PRIMARY KEY (id)
);
CREATE TABLE IF NOT EXISTS domain_admins (
    username varchar(255) NOT NULL DEFAULT '',
    domain varchar(255) NOT NULL DEFAULT '',
    created timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    active boolean NOT NULL DEFAULT true
);
CREATE TABLE IF NOT EXISTS fetchmail (
    id serial,
    mailbox varchar(255) NOT NULL DEFAULT '',
    src_server varchar(255) NOT NULL DEFAULT '',
    src_auth varchar(15) NOT NULL DEFAULT 'password',
    src_user varchar(255) NOT NULL DEFAULT '',
    src_password varchar(255) NOT NULL DEFAULT '',
    src_folder varchar(255) NOT NULL DEFAULT 'INBOX',
    poll_time int NOT NULL DEFAULT 10,
    fetchall boolean NOT NULL DEFAULT false,
    keep boolean NOT NULL DEFAULT false,
    protocol varchar(15) NOT NULL DEFAULT 'POP3',
    usessl boolean NOT NULL DEFAULT false,
    extra_options text,
    returned_text text,
    mda varchar(255) NOT NULL DEFAULT '',
    date timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id)
);
CREATE TABLE IF NOT EXISTS log (
    timestamp timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    username varchar(255) NOT NULL DEFAULT '',
    domain varchar(255) NOT NULL DEFAULT '',
    action varchar(255) NOT NULL DEFAULT '',
    data text NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS quota (
    username varchar(255) NOT NULL,
    path varchar(100) NOT NULL,
    current bigint DEFAULT 0,
    PRIMARY KEY (username,path)
);
CREATE TABLE IF NOT EXISTS quota2 (
    username varchar(100) NOT NULL,
    bytes bigint NOT NULL DEFAULT 0,
    messages int NOT NULL DEFAULT 0,
    PRIMARY KEY (username)
);
CREATE TABLE IF NOT EXISTS vacation (
    email varchar(255) NOT NULL DEFAULT '',
    subject varchar(255) NOT NULL DEFAULT '',
    body text NOT NULL DEFAULT '',
    cache text NOT NULL DEFAULT '',
    domain varchar(255) NOT NULL DEFAULT '',
    created timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    active boolean NOT NULL DEFAULT true,
    interval_time int NOT NULL DEFAULT 0,
    activefrom timestamp NOT NULL DEFAULT '1999-12-31 23:59:59',
    activeuntil timestamp NOT NULL DEFAULT '1999-12-31 23:59:59',
    PRIMARY KEY (email)
);
CREATE TABLE IF NOT EXISTS vacation_notification (
    on_vacation varchar(255) NOT NULL,
    notified varchar(255) NOT NULL,
    notified_at timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (on_vacation,notified)
);
-- Дополняем mailbox недостающими полями
ALTER TABLE mailbox ADD COLUMN IF NOT EXISTS phone varchar(20) NOT NULL DEFAULT '';
ALTER TABLE mailbox ADD COLUMN IF NOT EXISTS email_other varchar(255) NOT NULL DEFAULT '';
ALTER TABLE mailbox ADD COLUMN IF NOT EXISTS token varchar(255) NOT NULL DEFAULT '';
ALTER TABLE mailbox ADD COLUMN IF NOT EXISTS token_validity timestamp NOT NULL DEFAULT '1999-12-31 23:59:59';
ALTER TABLE mailbox ADD COLUMN IF NOT EXISTS password_expiry timestamp;
ALTER TABLE mailbox ADD COLUMN IF NOT EXISTS smtp_active boolean NOT NULL DEFAULT true;
ALTER TABLE mailbox ADD COLUMN IF NOT EXISTS pop3_active boolean NOT NULL DEFAULT true;
ALTER TABLE mailbox ADD COLUMN IF NOT EXISTS imap_active boolean NOT NULL DEFAULT true;
ALTER TABLE mailbox ADD COLUMN IF NOT EXISTS sieve_active boolean NOT NULL DEFAULT true;
-- Вставляем версию конфигурации
INSERT INTO config (name, value) VALUES ('version', '1840') ON CONFLICT DO NOTHING;
-- Добавляем недостающую колонку superadmin если её нет
ALTER TABLE admin ADD COLUMN IF NOT EXISTS superadmin boolean NOT NULL DEFAULT false;
-- Добавляем недостающие колонки в domain если их нет
ALTER TABLE domain ADD COLUMN IF NOT EXISTS defaultaliases boolean NOT NULL DEFAULT true;
ALTER TABLE domain ADD COLUMN IF NOT EXISTS password_expiry integer NOT NULL DEFAULT 0;
ADDTABLES
        if [[ $? -eq 0 ]]; then
            print_success "Схема дополнена недостающими таблицами"
            sql_found=true
        else
            print_error "Не удалось дополнить схему"
            log_error "Failed to extend database schema"
            [[ "$FORCE_MODE" != "true" ]] && exit 1
        fi
    else
        # Схема уже полная — ничего не делаем
        print_info "Схема базы данных уже полная"
        sql_found=true
    fi

    # Если схема создана или дополнена — помечаем как инициализированную
    if [[ "$sql_found" == "true" ]]; then
        touch "$POSTFIXADMIN_DIR/DATABASE_INITIALIZED"
        print_success "База данных PostfixAdmin инициализирована"
        log_info "PostfixAdmin database initialized"
    else
        print_error "Не удалось инициализировать базу данных PostfixAdmin"
        log_error "Failed to initialize PostfixAdmin database"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi

    unset PGPASSWORD PGUSER PGHOST PGDATABASE
else
    print_info "База данных PostfixAdmin уже инициализирована — пропуск"
    log_info "PostfixAdmin database already initialized — skipping"
fi

# --- Автоматическое создание домена и администратора ---
print_step "Автоматическое создание домена и администратора"
# Устанавливаем переменные окружения для подключения к БД
export PGPASSWORD="$ADMIN_PASSWORD"

# Проверяем, существует ли домен
domain_exists=$(psql -h localhost -U "$ADMIN_USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM domain WHERE domain='$DOMAIN';" 2>/dev/null | tr -d ' ')
if [[ "$domain_exists" == "0" ]]; then
    print_info "Добавление домена $DOMAIN в PostfixAdmin..."
    psql -h localhost -U "$ADMIN_USER" -d "$DB_NAME" <<-EOF >/dev/null 2>&1
INSERT INTO domain (domain, description, aliases, mailboxes, maxquota, quota, transport, backupmx, created, modified, active, defaultaliases, password_expiry)
VALUES ('$DOMAIN', 'Main domain', 10, 10, 0, 0, 'virtual', false, NOW(), NOW(), true, true, 0);
EOF
    if [[ $? -eq 0 ]]; then
        print_success "Домен $DOMAIN добавлен"
        log_info "Domain $DOMAIN added to PostfixAdmin"
    else
        print_warning "Не удалось добавить домен $DOMAIN"
        log_warn "Failed to add domain $DOMAIN"
    fi
else
    print_info "Домен $DOMAIN уже существует в PostfixAdmin"
    log_info "Domain $DOMAIN already exists in PostfixAdmin"
fi

# Проверяем, существует ли администратор
admin_exists=$(psql -h localhost -U "$ADMIN_USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM admin WHERE username='$ADMIN_EMAIL';" 2>/dev/null | tr -d ' ')
if [[ "$admin_exists" == "0" ]]; then
    print_info "Создание администратора $ADMIN_EMAIL в PostfixAdmin..."
    # Генерируем хеш пароля (совместимый с PostfixAdmin)
    admin_password_hash=$(php -r "echo password_hash('$ADMIN_PASSWORD', PASSWORD_DEFAULT);")
    psql -h localhost -U "$ADMIN_USER" -d "$DB_NAME" <<-EOF >/dev/null 2>&1
INSERT INTO admin (username, password, superadmin, created, modified, active)
VALUES ('$ADMIN_EMAIL', '$admin_password_hash', true, NOW(), NOW(), true);
EOF
    if [[ $? -eq 0 ]]; then
        print_success "Администратор $ADMIN_EMAIL создан"
        log_info "Admin $ADMIN_EMAIL created in PostfixAdmin"
        print_info "Пароль администратора: ADMIN_PASSWORD"
    else
        print_warning "Не удалось создать администратора $ADMIN_EMAIL"
        log_warn "Failed to create admin $ADMIN_EMAIL"
    fi
else
    print_info "Администратор $ADMIN_EMAIL уже существует в PostfixAdmin"
    log_info "Admin $ADMIN_EMAIL already exists in PostfixAdmin"
fi

# --- Создание связи администратора с доменом ---
print_step "Создание связи администратора с доменом"
domain_admin_exists=$(psql -h localhost -U "$ADMIN_USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM domain_admins WHERE username='$ADMIN_EMAIL' AND domain='$DOMAIN';" 2>/dev/null | tr -d ' ')
if [[ "$domain_admin_exists" == "0" ]]; then
    print_info "Создание связи администратора с доменом..."
    psql -h localhost -U "$ADMIN_USER" -d "$DB_NAME" <<-EOF >/dev/null 2>&1
INSERT INTO domain_admins (username, domain, created, active)
VALUES ('$ADMIN_EMAIL', '$DOMAIN', NOW(), true);
INSERT INTO domain_admins (username, domain, created, active)
VALUES ('$ADMIN_EMAIL', 'ALL', NOW(), true);
EOF
    if [[ $? -eq 0 ]]; then
        print_success "Связь администратора с доменом создана"
        log_info "Admin domain association created"
    else
        print_warning "Не удалось создать связь администратора с доменом"
        log_warn "Failed to create admin domain association"
    fi
else
    print_info "Связь администратора с доменом уже существует"
fi

# --- Создание дополнительных почтовых ящиков из конфига ---
if [[ -n "$ADDITIONAL_MAILBOXES" ]]; then
    print_step "Создание дополнительных почтовых ящиков"
    
    # Функция создания почтового ящика
    create_mailbox() {
        local mb_user="$1"
        local mb_password="$2"
        local mb_email="$mb_user@$DOMAIN"
        local mb_name="$mb_user"
        
        # Проверяем существование ящика
        local mb_exists=$(psql -h localhost -U "$ADMIN_USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM mailbox WHERE username='$mb_email';" 2>/dev/null | tr -d ' ')
        
        if [[ "$mb_exists" == "0" ]]; then
            print_info "Создание почтового ящика $mb_email..."
            
            # Генерируем хеш пароля
            local password_hash=""
            # Используем doveadm pw если доступен, иначе fallback на md5crypt
            if command -v doveadm &> /dev/null; then
                password_hash=$(doveadm pw -s SHA512-CRYPT -p "$mb_password" 2>/dev/null | cut -d'}' -f2)
                if [[ -z "$password_hash" ]]; then
                    password_hash=$(doveadm pw -s SSHA256 -p "$mb_password" 2>/dev/null | cut -d'}' -f2)
                fi
            fi
            
            # Если doveadm не сработал, используем openssl для md5crypt
            if [[ -z "$password_hash" ]]; then
                local salt=$(openssl rand -base64 6 | tr -d "=+/" | cut -c1-8)
                password_hash=$(openssl passwd -1 -salt "$salt" "$mb_password")
            fi
            
            # Создаем maildir путь
            local maildir_path="${DOMAIN}/${mb_user}/"
            
            # Вставляем в базу данных
            psql -h localhost -U "$ADMIN_USER" -d "$DB_NAME" <<-SQLEOF >/dev/null 2>&1
INSERT INTO mailbox (
    username, password, name, maildir, quota, local_part, domain, 
    created, modified, active, phone, email_other, token, token_validity,
    smtp_active, pop3_active, imap_active, sieve_active
) VALUES (
    '$mb_email', '$password_hash', '$mb_name', '$maildir_path', 0, '$mb_user', '$DOMAIN',
    NOW(), NOW(), true, '', '', '', '1999-12-31 23:59:59',
    true, true, true, true
);
INSERT INTO alias (address, goto, domain, created, modified, active)
VALUES ('$mb_email', '$mb_email', '$DOMAIN', NOW(), NOW(), true);
SQLEOF
            
            if [[ $? -eq 0 ]]; then
                print_success "Почтовый ящик $mb_email создан"
                log_info "Mailbox $mb_email created"
                print_info "   • Email:  $mb_email"
                print_info "   • Пароль: mb_password"
                
                # Создаем физическую директорию maildir
                if [[ -n "$MAIL_VHOSTS_DIR" ]] && [[ -d "$MAIL_VHOSTS_DIR" ]]; then
                    local physical_maildir="$MAIL_VHOSTS_DIR/$maildir_path"
                    mkdir -p "$physical_maildir"/{new,cur,tmp}
                    chown -R vmail:vmail "$physical_maildir" 2>/dev/null || true
                    chmod -R 750 "$physical_maildir"
                fi
            else
                print_warning "Не удалось создать почтовый ящик $mb_email"
                log_warn "Failed to create mailbox $mb_email"
            fi
        else
            print_info "Почтовый ящик $mb_email уже существует"
            log_info "Mailbox $mb_email already exists"
        fi
    }
    
    # Обрабатываем список ящиков
    IFS=',' read -ra MAILBOXES <<< "$ADDITIONAL_MAILBOXES"
    for mailbox in "${MAILBOXES[@]}"; do
        IFS=':' read -ra MB_DATA <<< "$mailbox"
        MB_USER="${MB_DATA[0]}"
        MB_PASS="${MB_DATA[1]:-$ADMIN_PASSWORD}"
        
        if [[ -n "$MB_USER" ]]; then
            create_mailbox "$MB_USER" "$MB_PASS"
        fi
    done
else
    print_info "Дополнительные почтовые ящики не настроены (ADDITIONAL_MAILBOXES пуст)"
fi

# Убираем переменную пароль из окружения
unset PGPASSWORD

# --- Настройка виртуального хоста NGINX для PostfixAdmin ---
print_step "Настройка виртуального хоста NGINX для PostfixAdmin"
NGINX_SITE_CONF="/etc/nginx/sites-available/$POSTFIXADMIN_DOMAIN"

# Создаем отдельный виртуальный хост для поддомена
print_info "Создание конфигурации: $NGINX_SITE_CONF"
cat > "$NGINX_SITE_CONF" <<EOF
server {
    listen 80;
    server_name $POSTFIXADMIN_DOMAIN;
    root $POSTFIXADMIN_DIR/public;
    index index.php;
    access_log /var/log/nginx/${POSTFIXADMIN_DOMAIN}_access.log;
    error_log /var/log/nginx/${POSTFIXADMIN_DOMAIN}_error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }

    # Запретить доступ к конфигурационным файлам
    location ~* \.(conf|sql|log)$ {
        deny all;
    }
}
EOF

if [[ $? -eq 0 ]]; then
    print_success "Конфигурация NGINX для $POSTFIXADMIN_DOMAIN создана"
    log_info "NGINX configuration for $POSTFIXADMIN_DOMAIN created"

    # Активируем сайт
    print_info "Активация сайта..."
    if [[ ! -L "/etc/nginx/sites-enabled/$POSTFIXADMIN_DOMAIN" ]]; then
        ln -s "/etc/nginx/sites-available/$POSTFIXADMIN_DOMAIN" "/etc/nginx/sites-enabled/$POSTFIXADMIN_DOMAIN"
        if [[ $? -eq 0 ]]; then
            print_success "Сайт $POSTFIXADMIN_DOMAIN активирован"
            log_info "Site $POSTFIXADMIN_DOMAIN enabled"
        else
            print_error "Не удалось активировать сайт"
            log_error "Failed to enable site"
            [[ "$FORCE_MODE" != "true" ]] && exit 1
        fi
    else
        print_info "Сайт уже активирован"
    fi
else
    print_error "Не удалось создать конфигурацию NGINX"
    log_error "Failed to create NGINX configuration"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
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
    nginx -t
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# --- Финальная проверка и вывод информации ---
print_step "Проверка установки PostfixAdmin"

# Проверка доступности файлов
if [[ -f "$POSTFIXADMIN_DIR/public/index.php" ]]; then
    print_success "PostfixAdmin установлен корректно"
    log_info "PostfixAdmin installed successfully"
else
    print_error "Файлы PostfixAdmin не найдены"
    log_error "PostfixAdmin files not found"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# Проверка доступности веб-интерфейса
print_info "Проверка доступности веб-интерфейса..."
if curl -f -s "http://$POSTFIXADMIN_DOMAIN" >/dev/null 2>&1; then
    print_success "Веб-интерфейс PostfixAdmin доступен"
    log_info "PostfixAdmin web interface accessible"
else
    print_warning "Веб-интерфейс PostfixAdmin может быть недоступен"
    log_warn "PostfixAdmin web interface may not be accessible"
    print_info "Проверьте настройки NGINX и DNS"
fi

# --- Информация для пользователя ---
print_section "🛠️  ИНФОРМАЦИЯ О POSTFIXADMIN"

print_success "✅ PostfixAdmin успешно установлен и настроен"
print_info "URL для доступа:"
print_info "   • http://$POSTFIXADMIN_DOMAIN"
print_info "   • https://$POSTFIXADMIN_DOMAIN (после настройки SSL)"
print_info ""
print_success "✅ АВТОМАТИЧЕСКАЯ НАСТРОЙКА ЗАВЕРШЕНА:"
print_info "   • Домен $DOMAIN добавлен в систему"
print_info "   • Администратор: $ADMIN_EMAIL"
print_info "   • Пароль: ADMIN_PASSWORD"
print_info "   • База данных инициализирована"
print_info "   • Поддомен: $POSTFIXADMIN_DOMAIN"
print_info ""
print_info "🚀 ГОТОВО К ИСПОЛЬЗОВАНИЮ:"
print_info "   1. Перейдите по ссылке: http://$POSTFIXADMIN_DOMAIN"
print_info "   2. Войдите с учетными данными администратора выше"
print_info "   3. Начните создавать почтовые ящики и псевдонимы"
print_info "   4. Протестируйте почту"
print_info ""
print_info "Полезные команды:"
print_info "   • cd $POSTFIXADMIN_DIR"
print_info "   • php bin/upgrade.php --yes (обновление БД)"
print_info "   • systemctl restart nginx php8.2-fpm"
print_info ""
print_info "Конфигурационные файлы:"
print_info "   • $CONFIG_FILE"
print_info "   • /etc/nginx/sites-available/$POSTFIXADMIN_DOMAIN"

log_info "PostfixAdmin fully automated setup completed with test mailbox. Access URL: http://$POSTFIXADMIN_DOMAIN, Admin: $ADMIN_EMAIL, Test mailbox: $TEST_EMAIL"
