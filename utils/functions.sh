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
