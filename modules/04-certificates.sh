#!/bin/bash

# modules/04-certificates.sh - Установка репозиториев и SSL-сертификатов
# Часть Git Server Deployment Module System
# Предполагается, что colors.sh, logging.sh, functions.sh уже загружены

[[ -z "${UTIL_PRINT_LOADED}" ]] && source ./utils/print.sh 2>/dev/null
[[ -z "${UTIL_LOGGING_LOADED}" ]] && source ./utils/logging.sh 2>/dev/null
[[ -z "${UTIL_FUNCTIONS_LOADED}" ]] && source ./utils/functions.sh 2>/dev/null

log_info "Начало настройки репозиториев и сертификатов"

# --- Проверка: уже добавлен репозиторий Sury PHP? ---
if [[ -f /etc/apt/sources.list.d/php.list ]]; then
    if grep -q "packages.sury.org" /etc/apt/sources.list.d/php.list; then
        log_warning "Репозиторий Sury PHP уже добавлен — пропуск"
    else
        log_info "Замена существующего php.list"
        rm -f /etc/apt/sources.list.d/php.list
    fi
else
    log_info "Подготовка к добавлению репозитория Sury PHP"
fi

# --- Установка зависимостей для репозиториев ---
log_info "Установка необходимых пакетов для управления репозиториями"
require_command "lsb_release" "требуется для определения версии ОС"
require_command "gpg" "требуется для проверки GPG-ключей"

apt -y install apt-transport-https ca-certificates gnupg2 > /dev/null 2>&1 || {
    log_error "Не удалось установить пакеты для работы с репозиториями"
    exit 1
}

# --- Создание директории для ключей ---
keyring_dir="/etc/apt/keyrings"
safe_mkdir "$keyring_dir" "root:root" "755" || {
    log_error "Не удалось создать директорию: $keyring_dir"
    exit 1
}

# --- Загрузка GPG-ключа Sury PHP ---
gpg_url="https://packages.sury.org/php/apt.gpg"
gpg_path="$keyring_dir/php.gpg"

log_info "Загрузка GPG-ключа Sury PHP: $gpg_url"
if wget -qO - "$gpg_url" | gpg --dearmor > "$gpg_path"; then
    log_success "GPG-ключ Sury PHP сохранён: $gpg_path"
else
    log_error "Не удалось загрузить или обработать GPG-ключ: $gpg_url"
    exit 1
fi

# Проверка прав
chown root:root "$gpg_path"
chmod 644 "$gpg_path"

# --- Добавление репозитория Sury PHP ---
codename=$(lsb_release -sc)
repo_line="deb [signed-by=$gpg_path] https://packages.sury.org/php/ $codename main"
repo_file="/etc/apt/sources.list.d/php.list"

log_info "Добавление репозитория Sury PHP для $codename"
echo "$repo_line" > "$repo_file"

if [[ $? -eq 0 ]]; then
    log_success "Репозиторий Sury PHP добавлен: $repo_file"
else
    log_error "Не удалось записать файл репозитория: $repo_file"
    exit 1
fi

# --- Обновление списка пакетов ---
log_info "Обновление списка пакетов (apt update)"
if apt update > /dev/null 2>&1; then
    log_success "Список пакетов обновлён"
else
    log_error "Ошибка при выполнении 'apt update'"
    exit 1
fi

# --- Выбор SSL-провайдера из конфига ---
: "${SSL_PROVIDER:=letsencrypt}"

case "$SSL_PROVIDER" in
    "letsencrypt")
        log_info "Настройка Let's Encrypt (Certbot)"
        if ! command -v certbot &> /dev/null; then
            apt -y install certbot > /dev/null 2>&1 && \
                log_success "Certbot установлен" || \
                log_warn "Не удалось установить certbot"
        else
            log_info "Certbot уже установлен"
        fi
        ;;
    "self-signed")
        log_info "Генерация самоподписанного SSL-сертификата"
        local cert_dir="/etc/ssl/self-signed"
        safe_mkdir "$cert_dir" "root:root" "755"

        local key="$cert_dir/server.key"
        local crt="$cert_dir/server.crt"
        local days=365

        if openssl req -x509 -nodes -days "$days" \
            -newkey rsa:2048 \
            -keyout "$key" \
            -out "$crt" \
            -subj "/C=RU/ST=Default/L=Default/O=Default/CN=${DOMAIN:-localhost}" > /dev/null 2>&1; then
            chown root:root "$key" "$crt"
            chmod 600 "$key"
            chmod 644 "$crt"
            log_success "Самоподписанный сертификат создан: $crt"
        else
            log_error "Не удалось сгенерировать самоподписанный сертификат"
            exit 1
        fi
        ;;
    *)
        log_warn "Неизвестный провайдер SSL: $SSL_PROVIDER — пропуск"
        ;;
esac

# --- Дополнительное обновление системы (опционально) ---
if [[ "${AUTO_UPGRADE:-true}" == "true" ]]; then
    log_info "Выполняется обновление системы (apt upgrade)"
    apt -y upgrade > /dev/null 2>&1 && log_success "Система обновлена"
fi

log_success "Настройка сертификатов и репозиториев завершена"