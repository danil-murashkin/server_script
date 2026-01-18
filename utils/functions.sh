#!/bin/bash
# utils/functions.sh - Общие функции
# Часть Git Server Deployment Module System

UTIL_FUNCTIONS_LOADED=true

ensure_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "Требуется root"
        exit 1
    fi
}

ensure_debian() {
    if ! grep -q "Debian" /etc/os-release 2>/dev/null; then
        log_error "Поддерживается только Debian 11+"
        print_error "Только Debian"
        exit 1
    fi
    local version=$(grep VERSION_ID /etc/os-release | cut -d= -f2 | tr -d '"' | cut -d. -f1)
    if [[ "$version" -lt 11 ]]; then
        print_error "Требуется Debian 11+, найдено: $version"
        exit 1
    fi
}


# Загружает конфиг из ./config/main.conf, если DOMAIN или SERVER_IP не заданы
load_config() {
    if [[ -z "$DOMAIN" ]] || [[ -z "$SERVER_IP" ]]; then
        print_info "Конфигурация не загружена — поиск ./config/main.conf..."
        local config_path="./config/main.conf"
        
        if [[ -f "$config_path" ]]; then
            source "$config_path" 2>/dev/null
            print_success "Конфигурация загружена: $config_path"
            log_info "Configuration loaded from: $config_path"
        else
            print_error "Файл конфигурации не найден: $config_path"
            log_error "Config file not found: $config_path"
            return 1
        fi
    fi
}


# Проверка наличия команды
require_command() {
    local cmd="$1"
    local desc="${2:-необходимая команда}"
    if ! command -v "$cmd" &> /dev/null; then
        print_error "Отсутствует: $cmd ($desc)"
        log_error "Command not found: $cmd ($desc)"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
}

# Безопасное создание директории
# Если директория существует — не ошибка, просто проверяем права
safe_mkdir() {
    local dir="$1"
    local owner="${2:-root:root}"
    local perms="${3:-755}"

    # Пытаемся создать директорию, игнорируя ошибку "уже существует"
    if mkdir -p "$dir" 2>/dev/null; then
        :
    else
        # Если mkdir не сработал, проверим, существует ли директория
        if [[ ! -d "$dir" ]]; then
            print_error "Не удалось создать директорию: $dir"
            log_error "Failed to create directory: $dir"
            return 1
        fi
    fi

    # Устанавливаем владельца и права в любом случае
    if chown "$owner" "$dir" && chmod "$perms" "$dir"; then
        log_debug "Директория настроена: $dir (владелец: $owner, права: $perms)"
        return 0
    else
        print_error "Не удалось установить права для: $dir"
        log_error "Failed to set permissions/owner for: $dir"
        return 1
    fi
}

# Пример: безопасное создание файла
safe_touch() {
    local file="$1"
    local owner="${2:-root:root}"
    local perms="${3:-644}"

    # Создаём родительские директории
    local dir=$(dirname "$file")
    safe_mkdir "$dir" "$owner" "755" || return 1

    # Создаём файл, если его нет
    if [[ ! -f "$file" ]]; then
        touch "$file" || { print_error "Не удалось создать файл: $file"; return 1; }
    fi

    # Устанавливаем права
    chown "$owner" "$file" && chmod "$perms" "$file" || {
        print_error "Не удалось установить права для: $file"
        return 1
    }
    log_debug "Файл настроен: $file"
}


# ========================================
# SSL ФУНКЦИИ
# ========================================

# Получить путь к SSL сертификату в зависимости от провайдера
# Использование: SSL_CERT=$(get_ssl_cert_path "$DOMAIN")
get_ssl_cert_path() {
    local domain="${1:-$DOMAIN}"
    
    case "$SSL_PROVIDER" in
        "letsencrypt")
            echo "/etc/letsencrypt/live/$domain/fullchain.pem"
            ;;
        "self-signed")
            echo "/etc/ssl/self-signed/server.crt"
            ;;
        "custom")
            echo "${SSL_CUSTOM_DIR:-/etc/ssl/custom}/fullchain.pem"
            ;;
        *)
            # Fallback на snakeoil если провайдер неизвестен
            echo "/etc/ssl/certs/ssl-cert-snakeoil.pem"
            ;;
    esac
}

# Получить путь к приватному ключу SSL в зависимости от провайдера
# Использование: SSL_KEY=$(get_ssl_key_path "$DOMAIN")
get_ssl_key_path() {
    local domain="${1:-$DOMAIN}"
    
    case "$SSL_PROVIDER" in
        "letsencrypt")
            echo "/etc/letsencrypt/live/$domain/privkey.pem"
            ;;
        "self-signed")
            echo "/etc/ssl/self-signed/server.key"
            ;;
        "custom")
            echo "${SSL_CUSTOM_DIR:-/etc/ssl/custom}/privkey.pem"
            ;;
        *)
            # Fallback на snakeoil если провайдер неизвестен
            echo "/etc/ssl/private/ssl-cert-snakeoil.key"
            ;;
    esac
}

# Получить SSL сертификат от Let's Encrypt
# Использование: obtain_letsencrypt_certificate "domain.com" "/var/www/domain"
obtain_letsencrypt_certificate() {
    local domain="$1"
    local webroot="${2:-/var/www/$domain}"
    
    # Проверка обязательных параметров
    if [[ -z "$domain" ]]; then
        log_error "Domain not specified for obtain_letsencrypt_certificate"
        print_error "Не указан домен для получения сертификата"
        return 1
    fi
    
    if [[ -z "${ADMIN_EMAIL}" ]]; then
        log_error "ADMIN_EMAIL not set for Let's Encrypt"
        print_error "ADMIN_EMAIL не установлен в конфигурации"
        return 1
    fi
    
    # Проверка наличия certbot
    if ! command -v certbot &> /dev/null; then
        log_error "Certbot not installed"
        print_error "Certbot не установлен. Запустите модуль 04-certificates.sh"
        return 1
    fi
    
    print_step "Получение Let's Encrypt сертификата для $domain"
    log_info "Requesting Let's Encrypt certificate for $domain"
    
    # Формируем команду certbot
    local certbot_cmd="certbot certonly --webroot"
    certbot_cmd="$certbot_cmd -w $webroot"
    certbot_cmd="$certbot_cmd -d $domain"
    certbot_cmd="$certbot_cmd --non-interactive"
    certbot_cmd="$certbot_cmd --agree-tos"
    certbot_cmd="$certbot_cmd --email ${ADMIN_EMAIL}"
    
    # Добавляем staging если включено
    if [[ "${SSL_USE_STAGING:-false}" == "true" ]]; then
        certbot_cmd="$certbot_cmd --staging"
        print_warning "Используется тестовая среда Let's Encrypt (сертификат не будет доверенным)"
        log_warn "Using Let's Encrypt STAGING environment"
    fi
    
    # Выполняем получение сертификата
    if $certbot_cmd > /dev/null 2>&1; then
        print_success "SSL сертификат получен для $domain"
        log_info "SSL certificate obtained successfully for $domain"
        return 0
    else
        print_error "Не удалось получить сертификат для $domain"
        log_error "Failed to obtain Let's Encrypt certificate for $domain"
        
        print_info "Проверьте следующее:"
        print_info "  1. Домен $domain правильно настроен в DNS и указывает на IP этого сервера"
        print_info "  2. Порт 80 открыт и доступен из интернета"
        print_info "  3. NGINX обслуживает домен $domain и директория $webroot доступна"
        print_info "  4. Файрвол (UFW) не блокирует входящие соединения на порт 80"
        
        log_error "Let's Encrypt validation failed. Check DNS, port 80 access, and NGINX configuration"
        return 1
    fi
}

# Проверка существования SSL сертификатов
# Использование: if check_ssl_certificate_exists "$DOMAIN"; then ...
check_ssl_certificate_exists() {
    local domain="${1:-$DOMAIN}"
    
    local cert_path=$(get_ssl_cert_path "$domain")
    local key_path=$(get_ssl_key_path "$domain")
    
    if [[ -f "$cert_path" ]] && [[ -f "$key_path" ]]; then
        log_debug "SSL certificates found for $domain: $cert_path, $key_path"
        return 0
    else
        log_debug "SSL certificates NOT found for $domain"
        return 1
    fi
}

# Универсальная функция настройки SSL сертификата
# Автоматически выбирает метод получения на основе SSL_PROVIDER
# Использование: setup_ssl_certificate "domain.com" "/var/www/domain"
setup_ssl_certificate() {
    local domain="$1"
    local webroot="${2:-/var/www/$domain}"
    
    # Проверка что SSL включен
    if [[ "${ENABLE_SSL:-true}" != "true" ]]; then
        log_info "SSL disabled in configuration (ENABLE_SSL=false)"
        print_info "SSL отключен в конфигурации"
        return 0
    fi
    
    # Проверка обязательных параметров
    if [[ -z "$domain" ]]; then
        log_error "Domain not specified for setup_ssl_certificate"
        print_error "Не указан домен"
        return 1
    fi
    
    log_info "Setting up SSL certificate for $domain using provider: $SSL_PROVIDER"
    
    case "$SSL_PROVIDER" in
        "letsencrypt")
            # Проверяем, есть ли уже сертификат
            if check_ssl_certificate_exists "$domain"; then
                print_info "SSL сертификат для $domain уже существует"
                log_info "SSL certificate for $domain already exists - skipping"
                return 0
            fi
            
            # Получаем новый сертификат
            print_step "Запрос SSL сертификата от Let's Encrypt для $domain"
            obtain_letsencrypt_certificate "$domain" "$webroot"
            return $?
            ;;
            
        "self-signed")
            # Для self-signed сертификаты уже созданы в модуле 04
            # Они общие для всех доменов/поддоменов (благодаря SAN)
            if check_ssl_certificate_exists "$domain"; then
                print_success "Самоподписанный SSL сертификат найден"
                log_info "Self-signed SSL certificate found for $SSL_PROVIDER"
                return 0
            else
                print_error "Самоподписанные SSL сертификаты не найдены"
                print_info "Запустите модуль 04-certificates.sh для создания сертификатов"
                log_error "Self-signed SSL certificates not found. Run module 04-certificates.sh"
                return 1
            fi
            ;;
            
        "custom")
            # Для custom сертификаты уже скопированы в модуле 04
            # Они общие для всех доменов (wildcard или multi-domain)
            if check_ssl_certificate_exists "$domain"; then
                print_success "Пользовательский SSL сертификат найден"
                log_info "Custom SSL certificate found"
                return 0
            else
                print_error "Пользовательские SSL сертификаты не найдены"
                print_info "Запустите модуль 04-certificates.sh и укажите пути к сертификатам в main.conf"
                log_error "Custom SSL certificates not found. Run module 04-certificates.sh"
                return 1
            fi
            ;;
            
        *)
            log_warn "Unknown SSL_PROVIDER: $SSL_PROVIDER - skipping SSL setup"
            print_warning "Неизвестный провайдер SSL: $SSL_PROVIDER"
            return 1
            ;;
    esac
}

# Получить информацию о SSL сертификате
# Использование: get_ssl_certificate_info "$DOMAIN"
get_ssl_certificate_info() {
    local domain="${1:-$DOMAIN}"
    local cert_path=$(get_ssl_cert_path "$domain")
    
    if [[ ! -f "$cert_path" ]]; then
        print_warning "Сертификат не найден: $cert_path"
        return 1
    fi
    
    print_info "Информация о SSL сертификате:"
    
    # Common Name
    local cn=$(openssl x509 -in "$cert_path" -noout -subject 2>/dev/null | sed 's/.*CN *= *//')
    [[ -n "$cn" ]] && print_info "  CN (Common Name): $cn"
    
    # Издатель
    local issuer=$(openssl x509 -in "$cert_path" -noout -issuer 2>/dev/null | sed 's/.*CN *= *//')
    [[ -n "$issuer" ]] && print_info "  Издатель: $issuer"
    
    # Даты действия
    local start_date=$(openssl x509 -in "$cert_path" -noout -startdate 2>/dev/null | sed 's/notBefore=//')
    local end_date=$(openssl x509 -in "$cert_path" -noout -enddate 2>/dev/null | sed 's/notAfter=//')
    [[ -n "$start_date" ]] && print_info "  Начало действия: $start_date"
    [[ -n "$end_date" ]] && print_info "  Истекает: $end_date"
    
    # SAN (Subject Alternative Names)
    local san=$(openssl x509 -in "$cert_path" -noout -text 2>/dev/null | grep -A1 "Subject Alternative Name" | tail -1 | sed 's/^ *//')
    [[ -n "$san" ]] && print_info "  SAN: $san"
    
    return 0
}
