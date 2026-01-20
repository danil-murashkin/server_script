#!/bin/bash

# modules/04-certificates.sh - Установка репозиториев и SSL-сертификатов
# Часть Git Server Deployment Module System
# Предполагается, что colors.sh, logging.sh, functions.sh уже загружены

[[ -z "${UTIL_PRINT_LOADED}" ]] && source ./utils/print.sh 2>/dev/null
[[ -z "${UTIL_LOGGING_LOADED}" ]] && source ./utils/logging.sh 2>/dev/null
[[ -z "${UTIL_FUNCTIONS_LOADED}" ]] && source ./utils/functions.sh 2>/dev/null

# --- Загружаем конфиг ---
load_config || {
    print_error "Не удалось загрузить конфигурацию"
    log_error "Failed to load required configuration"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
}

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
    log_info "GPG-ключ Sury PHP сохранён: $gpg_path"
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
    log_info "Репозиторий Sury PHP добавлен: $repo_file"
else
    log_error "Не удалось записать файл репозитория: $repo_file"
    exit 1
fi

# --- Обновление списка пакетов ---
log_info "Обновление списка пакетов (apt update)"
if apt update > /dev/null 2>&1; then
    log_info "Список пакетов обновлён"
else
    log_error "Ошибка при выполнении 'apt update'"
    exit 1
fi

# --- Выбор SSL-провайдера из конфига ---
: "${SSL_PROVIDER:=letsencrypt}"

case "$SSL_PROVIDER" in
    "letsencrypt")
        log_info "Настройка Let's Encrypt (Certbot)"
        
        # Устанавливаем certbot с плагином для NGINX
        if ! command -v certbot &> /dev/null; then
            log_info "Установка certbot и python3-certbot-nginx..."
            apt -y install certbot python3-certbot-nginx > /dev/null 2>&1 && \
                log_info "Certbot и плагин для NGINX установлены" || \
                log_warn "Не удалось установить certbot"
        else
            log_info "Certbot уже установлен"
        fi
        
        # Проверка наличия автопродления
        if systemctl list-timers 2>/dev/null | grep -q certbot.timer; then
            log_info "Автопродление Let's Encrypt настроено (systemd timer)"
        elif [[ -f /etc/cron.d/certbot ]]; then
            log_info "Автопродление Let's Encrypt настроено (cron)"
        else
            log_info "Автопродление будет настроено автоматически при первом получении сертификата"
        fi
        ;;
        
    "self-signed")
        log_info "Генерация самоподписанного SSL-сертификата с SAN"
        local cert_dir="/etc/ssl/self-signed"
        safe_mkdir "$cert_dir" "root:root" "755"

        local key="$cert_dir/server.key"
        local crt="$cert_dir/server.crt"
        local days=3650  # 10 лет вместо 1 года
        
        # Создаем временный конфиг OpenSSL с поддержкой SAN (Subject Alternative Names)
        # для всех поддоменов и IP адреса
        local openssl_cnf="/tmp/openssl-san.cnf"
        cat > "$openssl_cnf" <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = v3_req

[dn]
C=RU
ST=Default
L=Default
O=Default
CN=${DOMAIN:-localhost}

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${DOMAIN:-localhost}
DNS.2 = www.${DOMAIN:-localhost}
DNS.3 = mail.${DOMAIN:-localhost}
DNS.4 = mailadmin.${DOMAIN:-localhost}
DNS.5 = webmail.${DOMAIN:-localhost}
DNS.6 = git.${DOMAIN:-localhost}
DNS.7 = cloud.${DOMAIN:-localhost}
DNS.8 = proxy.${DOMAIN:-localhost}
DNS.9 = vpn.${DOMAIN:-localhost}
IP.1 = ${SERVER_IP:-127.0.0.1}
EOF

        # Генерируем сертификат с SAN
        if openssl req -x509 -nodes -days "$days" \
            -newkey rsa:2048 \
            -keyout "$key" \
            -out "$crt" \
            -config "$openssl_cnf" \
            -extensions v3_req > /dev/null 2>&1; then
            
            chown root:root "$key" "$crt"
            chmod 600 "$key"
            chmod 644 "$crt"
            rm -f "$openssl_cnf"
            
            log_info "Самоподписанный сертификат создан: $crt"
            log_info "Сертификат включает SAN для всех поддоменов и IP: ${SERVER_IP:-127.0.0.1}"
            log_info "Срок действия: 10 лет (${days} дней)"
        else
            log_error "Не удалось сгенерировать самоподписанный сертификат"
            rm -f "$openssl_cnf"
            exit 1
        fi
        ;;
        
    "custom")
        log_info "Настройка пользовательских SSL-сертификатов"
        
        # Проверка обязательных параметров
        if [[ -z "$SSL_CUSTOM_CERT_PATH" ]] || [[ -z "$SSL_CUSTOM_KEY_PATH" ]]; then
            log_error "Не указаны пути к сертификатам"
            log_error "Установите SSL_CUSTOM_CERT_PATH и SSL_CUSTOM_KEY_PATH в main.conf"
            exit 1
        fi
        
        # Проверка существования файлов
        if [[ ! -f "$SSL_CUSTOM_CERT_PATH" ]]; then
            log_error "Файл сертификата не найден: $SSL_CUSTOM_CERT_PATH"
            exit 1
        fi
        
        if [[ ! -f "$SSL_CUSTOM_KEY_PATH" ]]; then
            log_error "Файл приватного ключа не найден: $SSL_CUSTOM_KEY_PATH"
            exit 1
        fi
        
        # Создание директории для хранения сертификатов
        local cert_dir="${SSL_CUSTOM_DIR:-/etc/ssl/custom}"
        safe_mkdir "$cert_dir" "root:root" "755"
        
        log_info "Копирование сертификатов в $cert_dir"
        
        # Копирование сертификата
        if cp "$SSL_CUSTOM_CERT_PATH" "$cert_dir/cert.pem" && chmod 644 "$cert_dir/cert.pem"; then
            log_info "Сертификат скопирован: $cert_dir/cert.pem"
        else
            log_error "Не удалось скопировать сертификат"
            exit 1
        fi
        
        # Копирование приватного ключа
        if cp "$SSL_CUSTOM_KEY_PATH" "$cert_dir/privkey.pem" && chmod 600 "$cert_dir/privkey.pem"; then
            log_info "Приватный ключ скопирован: $cert_dir/privkey.pem"
        else
            log_error "Не удалось скопировать приватный ключ"
            exit 1
        fi
        
        # Копирование цепочки сертификатов (если указана)
        if [[ -n "$SSL_CUSTOM_CHAIN_PATH" ]] && [[ -f "$SSL_CUSTOM_CHAIN_PATH" ]]; then
            if cp "$SSL_CUSTOM_CHAIN_PATH" "$cert_dir/chain.pem" && chmod 644 "$cert_dir/chain.pem"; then
                log_info "Цепочка сертификатов скопирована: $cert_dir/chain.pem"
                
                # Создаем fullchain (сертификат + цепочка)
                cat "$cert_dir/cert.pem" "$cert_dir/chain.pem" > "$cert_dir/fullchain.pem"
                chmod 644 "$cert_dir/fullchain.pem"
                log_info "Создан fullchain.pem (сертификат + цепочка)"
            else
                log_error "Не удалось скопировать цепочку сертификатов"
                exit 1
            fi
        else
            log_info "Цепочка сертификатов не указана"
            # Если цепочки нет - fullchain = cert
            cp "$cert_dir/cert.pem" "$cert_dir/fullchain.pem"
            chmod 644 "$cert_dir/fullchain.pem"
            log_info "fullchain.pem = cert.pem (без цепочки)"
        fi
        
        # Валидация сертификата
        log_info "Проверка валидности сертификата..."
        if openssl x509 -in "$cert_dir/cert.pem" -noout -text > /dev/null 2>&1; then
            log_info "Сертификат валиден"
            
            # Показываем информацию о сертификате
            local cert_cn=$(openssl x509 -in "$cert_dir/cert.pem" -noout -subject | sed 's/.*CN *= *//')
            local cert_issuer=$(openssl x509 -in "$cert_dir/cert.pem" -noout -issuer | sed 's/.*CN *= *//')
            local cert_expires=$(openssl x509 -in "$cert_dir/cert.pem" -noout -enddate | sed 's/notAfter=//')
            
            log_info "Информация о сертификате:"
            log_info "  CN (Common Name): $cert_cn"
            log_info "  Издатель: $cert_issuer"
            log_info "  Истекает: $cert_expires"
        else
            log_error "Сертификат невалиден или поврежден"
            exit 1
        fi
        
        # Проверка соответствия ключа и сертификата
        log_info "Проверка соответствия ключа и сертификата..."
        local cert_modulus=$(openssl x509 -noout -modulus -in "$cert_dir/cert.pem" 2>/dev/null | openssl md5 2>/dev/null)
        local key_modulus=$(openssl rsa -noout -modulus -in "$cert_dir/privkey.pem" 2>/dev/null | openssl md5 2>/dev/null)
        
        if [[ -n "$cert_modulus" ]] && [[ "$cert_modulus" == "$key_modulus" ]]; then
            log_info "Ключ и сертификат соответствуют друг другу"
        else
            log_error "Ключ и сертификат НЕ соответствуют друг другу!"
            log_error "Убедитесь что вы указали правильную пару сертификат+ключ"
            exit 1
        fi
        
        log_info "Пользовательские SSL-сертификаты успешно настроены"
        ;;
        
    *)
        log_warn "Неизвестный провайдер SSL: $SSL_PROVIDER — пропуск настройки SSL"
        ;;
esac

# --- Дополнительное обновление системы (опционально) ---
if [[ "${AUTO_UPGRADE:-true}" == "true" ]]; then
    log_info "Выполняется обновление системы (apt upgrade)"
    apt -y upgrade > /dev/null 2>&1 && log_info "Система обновлена"
fi

log_info "Настройка сертификатов и репозиториев завершена"