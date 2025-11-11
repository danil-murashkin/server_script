#!/bin/bash

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UTILS_DIR="$PROJECT_DIR/utils"
CONFIG_DIR="$PROJECT_DIR/config"
MODULES_DIR="$PROJECT_DIR/modules"

source "$UTILS_DIR/print.sh"
source "$UTILS_DIR/functions.sh"
source "$UTILS_DIR/logging.sh"

CONFIG_FILE="$CONFIG_DIR/main.conf"
DRY_RUN=false
DEBUG_MODE=false
QUIET_MODE=false
FORCE_MODE=false
CUSTOM_MODULES=""
SKIP_MODULES=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config=*) CONFIG_FILE="${1#*=}" ;;
            --modules=*) CUSTOM_MODULES="${1#*=}" ;;
            --skip=*) SKIP_MODULES="${1#*=}" ;;
            --debug) DEBUG_MODE=true ;;
            --quiet) QUIET_MODE=true ;;
            --dry-run) DRY_RUN=true ;;
            --force) FORCE_MODE=true ;;
            --help|-h)
                echo "Использование: $0 [опции]"
                exit 0
                ;;
            *) print_error "Неизвестный аргумент: $1"; exit 1 ;;
        esac
        shift
    done
}

initialize() {
    print_header "Универсальный сервер — Установка"
    ensure_root
    ensure_debian

    [[ "$QUIET_MODE" == "true" ]] && enable_quiet_mode
    [[ "$DEBUG_MODE" == "true" ]] && set_log_level "DEBUG"



    # === ВАЖНО: load_config ДО init_logging ===
    load_config "$CONFIG_FILE"

    # Проверка и дополнение конфигурационного файла ДО его загрузки
    if [[ -f "$CONFIG_FILE" ]]; then
        # Проверяем DOMAIN
        if ! grep -q "^DOMAIN=" "$CONFIG_FILE"; then
            print_warning "Параметр DOMAIN отсутствует в конфигурации"
            read -p "Введите доменное имя сервера (например, example.com): " DOMAIN </dev/tty
            sed -i "8a DOMAIN=\"$DOMAIN\"" "$CONFIG_FILE"
        elif grep -q "^DOMAIN=\"\"" "$CONFIG_FILE" || grep -q "^DOMAIN=''$" "$CONFIG_FILE" || grep -q "^DOMAIN=$" "$CONFIG_FILE"; then
            print_warning "Параметр DOMAIN пустой"
            read -p "Введите доменное имя сервера (например, example.com): " DOMAIN </dev/tty
            sed -i "s|^DOMAIN=.*|DOMAIN=\"$DOMAIN\"|" "$CONFIG_FILE"
        fi
        
        # Проверяем SERVER_IP
        if ! grep -q "^SERVER_IP=" "$CONFIG_FILE"; then
            print_warning "Параметр SERVER_IP отсутствует в конфигурации"
            read -p "Введите внешний IP-адрес сервера (или Enter для пропуска): " SERVER_IP </dev/tty
            if [[ -n "$SERVER_IP" ]]; then
                sed -i "8a SERVER_IP=\"$SERVER_IP\"" "$CONFIG_FILE"
            fi
        elif grep -q "^SERVER_IP=\"\"" "$CONFIG_FILE" || grep -q "^SERVER_IP=''$" "$CONFIG_FILE" || grep -q "^SERVER_IP=$" "$CONFIG_FILE"; then
            print_warning "Параметр SERVER_IP пустой"
            read -p "Введите внешний IP-адрес сервера (или Enter для пропуска): " SERVER_IP </dev/tty
            if [[ -n "$SERVER_IP" ]]; then
                sed -i "s|^SERVER_IP=.*|SERVER_IP=\"$SERVER_IP\"|" "$CONFIG_FILE"
            fi
        fi
        
        # Проверяем ADMIN_EMAIL
        if ! grep -q "^ADMIN_EMAIL=" "$CONFIG_FILE"; then
            print_warning "Параметр ADMIN_EMAIL отсутствует в конфигурации"
            read -p "Введите email администратора: " ADMIN_EMAIL </dev/tty
            sed -i "8a ADMIN_EMAIL=\"$ADMIN_EMAIL\"" "$CONFIG_FILE"
        elif grep -q "^ADMIN_EMAIL=\"\"" "$CONFIG_FILE" || grep -q "^ADMIN_EMAIL=''$" "$CONFIG_FILE" || grep -q "^ADMIN_EMAIL=$" "$CONFIG_FILE"; then
            print_warning "Параметр ADMIN_EMAIL пустой"
            read -p "Введите email администратора: " ADMIN_EMAIL </dev/tty
            sed -i "s|^ADMIN_EMAIL=.*|ADMIN_EMAIL=\"$ADMIN_EMAIL\"|" "$CONFIG_FILE"
        fi
        
        # Проверяем ADMIN_PASSWORD
        if ! grep -q "^ADMIN_PASSWORD=" "$CONFIG_FILE"; then
            print_warning "Параметр ADMIN_PASSWORD отсутствует в конфигурации"
            read -sp "Введите пароль администратора: " ADMIN_PASSWORD </dev/tty
            echo
            sed -i "8a ADMIN_PASSWORD=\"$ADMIN_PASSWORD\"" "$CONFIG_FILE"
        elif grep -q "^ADMIN_PASSWORD=\"\"" "$CONFIG_FILE" || grep -q "^ADMIN_PASSWORD=''$" "$CONFIG_FILE" || grep -q "^ADMIN_PASSWORD=$" "$CONFIG_FILE"; then
            print_warning "Параметр ADMIN_PASSWORD пустой"
            read -sp "Введите пароль администратора: " ADMIN_PASSWORD </dev/tty
            echo
            sed -i "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=\"$ADMIN_PASSWORD\"|" "$CONFIG_FILE"
        fi
        
        # Проверяем ADMIN_USER
        if ! grep -q "^ADMIN_USER=" "$CONFIG_FILE"; then
            print_warning "Параметр ADMIN_USER отсутствует в конфигурации"
            read -p "Введите имя основного пользователя (по умолчанию: webadmin): " ADMIN_USER </dev/tty
            ADMIN_USER="${ADMIN_USER:-webadmin}"
            sed -i "8a ADMIN_USER=\"$ADMIN_USER\"" "$CONFIG_FILE"
        elif grep -q "^ADMIN_USER=\"\"" "$CONFIG_FILE" || grep -q "^ADMIN_USER=''$" "$CONFIG_FILE" || grep -q "^ADMIN_USER=$" "$CONFIG_FILE"; then
            print_warning "Параметр ADMIN_USER пустой"
            read -p "Введите имя основного пользователя (по умолчанию: webadmin): " ADMIN_USER </dev/tty
            ADMIN_USER="${ADMIN_USER:-webadmin}"
            sed -i "s|^ADMIN_USER=.*|ADMIN_USER=\"$ADMIN_USER\"|" "$CONFIG_FILE"
        fi
        
        print_success "Проверка конфигурации завершена"
    fi

    [[ -z "$SKIP_MODULES" ]] && SKIP_MODULES="${SKIP_MODULES:-}"

    # Теперь LOG_FILE и LOG_LEVEL из main.conf доступны
    init_logging

    log_info "Установка начата"
}

get_modules() {
    local modules=()
    while IFS= read -r file; do
        [[ -f "$file" ]] && modules+=("$(basename "$file")")
    done < <(find "$MODULES_DIR" -name "*.sh" -type f | sort)
    echo "${modules[@]}"
}

run_installation() {
    local modules=($(get_modules))
    local executed=0 skipped=0

    for module in "${modules[@]}"; do
        local name="${module%.sh}"

        if [[ -n "$CUSTOM_MODULES" ]] && [[ ! ",$CUSTOM_MODULES," == *",$name,"* ]]; then
            continue
        fi

        if [[ -n "$SKIP_MODULES" ]] && [[ ",$SKIP_MODULES," == *",$name,"* ]]; then
            log_warn "Пропуск: $module"
            ((skipped++))
            continue
        fi

        log_module_start "$module"

        if [[ "$DRY_RUN" == "true" ]]; then
            print_step "(DRY RUN) $module"
            log_info "[DRY RUN] $module"
        else
            if bash "$MODULES_DIR/$module"; then
                log_module_done "$module"
                ((executed++))
            else
                log_error "Ошибка модуля: $module"
                if [[ "$FORCE_MODE" != "true" ]]; then
                    print_error "Установка прервана"
                    exit 1
                fi
            fi
        fi
    done

    print_header "Установка завершена"
    print_info "Выполнено: $executed, Пропущено: $skipped"
    [[ "$DRY_RUN" == "true" ]] && print_warning "Это был dry-run"
    print_success "Сервер развёрнут!"
}

main() {
    parse_args "$@"
    initialize
    run_installation
}

main "$@"
