#!/bin/bash
# modules/09-database.sh - Установка и настройка PostgreSQL
# Часть Mail Server Deployment Module System

# --- Загрузка вспомогательных утилит ---
[[ -z "${UTIL_PRINT_LOADED}" ]] && source ./utils/print.sh 2>/dev/null
[[ -z "${UTIL_LOGGING_LOADED}" ]] && source ./utils/logging.sh 2>/dev/null
[[ -z "${UTIL_FUNCTIONS_LOADED}" ]] && source ./utils/functions.sh 2>/dev/null

# --- Проверка прав root ---
ensure_root

# --- Загружаем конфиг, если нужно ---
load_config || {
    print_error "Не удалось загрузить конфигурацию. Убедитесь, что ./config/main.conf существует и содержит DOMAIN, SERVER_IP, ADMIN_USER, ADMIN_PASSWORD."
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
require_command "wget" "загрузка репозиториев"
require_command "curl" "загрузка ключей"

# --- Установка PostgreSQL из официального репозитория ---
print_step "Добавление официального репозитория PostgreSQL"

# Определяем версию Debian
CODENAME=$(lsb_release -cs 2>/dev/null)

if [[ -z "$CODENAME" ]]; then
    print_error "Не удалось определить кодовое имя дистрибутива"
    log_error "Failed to detect distribution codename"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# Создаём директорию для ключей
safe_mkdir "/etc/apt/keyrings" "root:root" "755"

# Импортируем ключ (всегда перезаписываем без запроса)
print_step "Импорт GPG-ключа PostgreSQL"
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | \
    gpg --dearmor --yes -o /etc/apt/keyrings/postgresql.gpg > /dev/null 2>&1

if [[ $? -eq 0 ]]; then
    print_success "Ключ PostgreSQL импортирован (перезаписан, если существовал)"
    log_info "PostgreSQL GPG key imported (overwritten if existed)"
else
    print_error "Не удалось импортировать ключ PostgreSQL"
    log_error "Failed to import PostgreSQL GPG key"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# Добавляем репозиторий
print_step "Добавление репозитория PostgreSQL в sources.list.d"
cat > /etc/apt/sources.list.d/pgdg.list <<EOF
deb [signed-by=/etc/apt/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt/ $CODENAME-pgdg main
EOF

if [[ $? -eq 0 ]]; then
    print_success "Репозиторий PostgreSQL добавлен"
    log_info "PostgreSQL repository added for $CODENAME"
else
    print_error "Не удалось добавить репозиторий PostgreSQL"
    log_error "Failed to add PostgreSQL repository"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# Обновляем кеш пакетов
print_step "Обновление списка пакетов"
if apt update -qq > /dev/null 2>&1; then
    print_success "Список пакетов обновлён"
    log_info "Package list updated"
else
    print_error "Не удалось обновить список пакетов"
    log_error "Failed to update package list"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# --- Установка PostgreSQL ---
print_step "Установка PostgreSQL и contrib"
if ! command -v psql &> /dev/null; then
    if apt install -y postgresql postgresql-contrib > /dev/null 2>&1; then
        print_success "PostgreSQL успешно установлен"
        log_info "PostgreSQL installed successfully"
    else
        print_error "Не удалось установить PostgreSQL"
        log_error "Failed to install PostgreSQL"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
else
    print_success "PostgreSQL уже установлен"
    log_info "PostgreSQL is already installed"
fi

# --- Настройка пароля для пользователя postgres ---
print_step "Настройка пароля для системного пользователя postgres"
sudo -u postgres psql -c "ALTER USER postgres PASSWORD '$ADMIN_PASSWORD';" > /dev/null 2>&1
if [[ $? -eq 0 ]]; then
    print_success "Пароль для 'postgres' установлен"
    log_info "Password for 'postgres' user set"
else
    print_error "Не удалось установить пароль для 'postgres'"
    log_error "Failed to set password for 'postgres' user"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# --- Создание пользователя и базы данных для веб-приложений ---
WEB_DB_USER="${ADMIN_USER}"
WEB_DB_NAME="${DOMAIN//./_}"  # Заменяем точки на подчёркивания

print_step "Создание пользователя БД: $WEB_DB_USER"
sudo -u postgres psql -c "CREATE USER $WEB_DB_USER WITH PASSWORD '$ADMIN_PASSWORD';" > /dev/null 2>&1
if [[ $? -eq 0 ]]; then
    print_success "Пользователь $WEB_DB_USER создан"
    log_info "Database user $WEB_DB_USER created"
else
    # Если пользователь уже существует — не ошибка
    if sudo -u postgres psql -c "\\du" | grep -q "$WEB_DB_USER"; then
        print_info "Пользователь $WEB_DB_USER уже существует — пропуск"
        log_info "Database user $WEB_DB_USER already exists — skipping"
    else
        print_error "Не удалось создать пользователя $WEB_DB_USER"
        log_error "Failed to create database user $WEB_DB_USER"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
fi

print_step "Создание базы данных: $WEB_DB_NAME (владелец: $WEB_DB_USER)"
sudo -u postgres psql -c "CREATE DATABASE $WEB_DB_NAME OWNER $WEB_DB_USER ENCODING 'UTF8' LC_COLLATE 'en_US.UTF-8' LC_CTYPE 'en_US.UTF-8' TEMPLATE template0;" > /dev/null 2>&1
if [[ $? -eq 0 ]]; then
    print_success "База данных $WEB_DB_NAME создана"
    log_info "Database $WEB_DB_NAME created with owner $WEB_DB_USER"
else
    # Если база уже существует — не ошибка
    if sudo -u postgres psql -l | grep -q "$WEB_DB_NAME"; then
        print_info "База данных $WEB_DB_NAME уже существует — пропуск"
        log_info "Database $WEB_DB_NAME already exists — skipping"
    else
        print_error "Не удалось создать базу данных $WEB_DB_NAME"
        log_error "Failed to create database $WEB_DB_NAME"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
fi

# --- Настройка аутентификации PostgreSQL ---
print_step "Настройка pg_hba.conf для локального доступа"
PG_HBA_CONF=$(find /etc/postgresql -name "pg_hba.conf" | head -1)

if [[ -z "$PG_HBA_CONF" ]]; then
    print_error "Файл pg_hba.conf не найден"
    log_error "pg_hba.conf not found"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# Создаём резервную копию
cp "$PG_HBA_CONF" "$PG_HBA_CONF.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null && \
    log_info "Backup of pg_hba.conf created"

# Добавляем правила для локального доступа (только если их ещё нет)
if ! grep -q "# === Добавлено скриптом установки ===" "$PG_HBA_CONF"; then
    {
        echo "# === Добавлено скриптом установки ==="
        echo "local   all             postgres                                md5"
        echo "local   all             $WEB_DB_USER                            md5"
        echo "local   all             all                                     peer"
        echo "host    all             all             127.0.0.1/32            md5"
        echo "host    all             all             ::1/128                 md5"
    } >> "$PG_HBA_CONF"
else
    print_info "Правила pg_hba.conf уже существуют — пропуск"
    log_info "pg_hba.conf rules already exist — skipping"
fi

if [[ $? -eq 0 ]]; then
    print_success "pg_hba.conf обновлён"
    log_info "pg_hba.conf updated"
else
    print_error "Не удалось обновить pg_hba.conf"
    log_error "Failed to update pg_hba.conf"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# --- Перезагрузка PostgreSQL ---
print_step "Перезагрузка службы PostgreSQL"
systemctl reload postgresql > /dev/null 2>&1 && \
    print_success "Служба PostgreSQL перезагружена" && \
    log_info "PostgreSQL service reloaded"

# --- Проверка доступа к базе данных ---
print_step "Проверка подключения к базе данных $WEB_DB_NAME"
PGPASSWORD="$ADMIN_PASSWORD" psql -U "$WEB_DB_USER" -d "$WEB_DB_NAME" -h localhost -c "SELECT 1;" > /dev/null 2>&1
if [[ $? -eq 0 ]]; then
    print_success "Подключение к базе данных успешно"
    log_info "Database connection test passed"
else
    print_error "Не удалось подключиться к базе данных"
    log_error "Database connection test failed"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# --- Настройка UFW ---
if [[ "${ENABLE_UFW:-true}" == "true" ]] && command -v ufw &> /dev/null; then
    print_step "Настройка UFW: разрешение PostgreSQL (5432)"
    if ufw status | grep -q "Status: active"; then
        if ! ufw status | grep -q "5432"; then
            ufw allow 5432/tcp > /dev/null 2>&1 && \
                print_success "Правило UFW для PostgreSQL применено" && \
                log_info "UFW rule for PostgreSQL applied"
        else
            print_info "Правило UFW для PostgreSQL уже существует — пропуск"
            log_info "UFW rule for PostgreSQL already exists — skipping"
        fi
    else
        print_warning "UFW не активен — правила не применены"
        log_warn "UFW is not active — skipping rule application"
    fi
else
    print_warning "UFW отключен или не установлен — пропуск настройки"
    log_warn "UFW disabled or not installed — skipping firewall config"
fi

# --- Информация для пользователя ---
print_section "🗄️  ИНФОРМАЦИЯ О БАЗЕ ДАННЫХ"

print_success "✅ PostgreSQL успешно установлен и настроен"
print_info "Системный пользователь:"
print_info "   • Имя: postgres"
print_info "   • Пароль: ADMIN_PASSWORD"
print_info ""
print_info "Пользователь для веб-приложений:"
print_info "   • Имя: $WEB_DB_USER"
print_info "   • Пароль: ADMIN_PASSWORD"
print_info "   • База данных: $WEB_DB_NAME"
print_info ""
print_info "Подключение:"
print_info "   psql -h localhost -U $WEB_DB_USER -d $WEB_DB_NAME"
print_info ""
print_info "Конфигурационные файлы:"
print_info "   • pg_hba.conf: $PG_HBA_CONF"
print_info "   • postgresql.conf: $(dirname "$PG_HBA_CONF")/postgresql.conf"

log_info "PostgreSQL setup completed. Web user: $WEB_DB_USER, Database: $WEB_DB_NAME"
