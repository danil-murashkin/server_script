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
BACKGROUND_MODE=false
FORCE_MODE=false
ARG_DOMAIN=""
ARG_SERVER_IP=""
ARG_ADMIN_EMAIL=""
ARG_ADMIN_PASSWORD=""
CUSTOM_MODULES=""
SKIP_MODULES=""
NO_DETACH=false

# Флаги для отслеживания, были ли параметры переданы через командную строку
ARG_DEBUG=false
ARG_BACKGROUND=false
ARG_DRY_RUN=false
ARG_FORCE=false

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config=*) CONFIG_FILE="${1#*=}" ;;
            --domain=*) ARG_DOMAIN="${1#*=}" ;;
            --ip=*) ARG_SERVER_IP="${1#*=}" ;;
            --email=*) ARG_ADMIN_EMAIL="${1#*=}" ;;
            --password=*) ARG_ADMIN_PASSWORD="${1#*=}" ;;
            --modules=*) CUSTOM_MODULES="${1#*=}" ;;
            --skip=*) SKIP_MODULES="${1#*=}" ;;
            --debug) DEBUG_MODE=true; ARG_DEBUG=true ;;
            --background) BACKGROUND_MODE=true; ARG_BACKGROUND=true ;;
            --dry-run) DRY_RUN=true; ARG_DRY_RUN=true ;;
            --force) FORCE_MODE=true; ARG_FORCE=true ;;
            --no-detach) NO_DETACH=true ;;
            --help|-h)
                cat << EOF
Использование: $0 [опции]

Опции:
  --config=FILE     Путь к конфигурационному файлу (по умолчанию: $CONFIG_FILE)
  --domain=DOMAIN   Доменное имя сервера
  --ip=IP           Внешний IP-адрес (если пусто - автоопределение)
  --email=EMAIL     Email администратора (если пусто - admin@domain)
  --password=PASS   Пароль администратора
  --modules=LIST    Список модулей для установки (через запятую)
  --skip=LIST       Список модулей для пропуска (через запятую)
  --debug           Включить режим отладки (DEBUG уровень логирования)
  --background      Фоновая установка - запуск в фоне с полным логированием
  --dry-run         Режим проверки без выполнения изменений
  --force           Принудительная установка (игнорировать предупреждения)
  --help, -h        Показать эту справку

Примеры:
  $0                                    # Обычная установка
  $0 --background                       # Фоновая установка с логированием
  $0 --modules=dns,nginx,postfix        # Установка только указанных модулей
  $0 --skip=vpn-wireguard,git-gitea     # Пропустить указанные модули
  $0 --debug                            # Установка с отладочным выводом
  $0 --dry-run                          # Проверка без изменений

При фоновой установке (--background):
  - Процесс запускается в фоне через nohup
  - Весь вывод сохраняется в логи
  - Можно закрыть терминал, установка продолжится
  - Логи: \$LOG_DIR/\$LOG_FILE и \$LOG_DIR/\$CONSOLE_LOG_FILE

Просмотр логов в реальном времени:
  tail -f ./logs/server-script-console.log
EOF
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

    # === ВАЖНО: load_config ДО init_logging ===
    load_config "$CONFIG_FILE"

    # Пересчитываем LOG_DIR после загрузки конфига
    if [[ -z "${LOG_DIR+x}" ]] || [[ -z "${LOG_DIR}" ]]; then
        LOG_DIR="$PROJECT_DIR/logs"
    elif [[ "${LOG_DIR}" != /* ]]; then
        # Если путь относительный (не начинается с /), делаем его относительно PROJECT_DIR
        LOG_DIR="$PROJECT_DIR/${LOG_DIR}"
    fi
    # Создаем директорию для логов
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    export LOG_DIR

    # Применение параметров из конфига (если не переопределены через командную строку)
    [[ "$ARG_DEBUG" == "false" ]] && DEBUG_MODE="${DEBUG_MODE:-false}"
    [[ "$ARG_BACKGROUND" == "false" ]] && BACKGROUND_MODE="${BACKGROUND_MODE:-false}"
    [[ "$ARG_DRY_RUN" == "false" ]] && DRY_RUN="${DRY_RUN:-false}"
    [[ "$ARG_FORCE" == "false" ]] && FORCE_MODE="${FORCE_MODE:-false}"

    # Проверка и дополнение конфигурационного файла ДО его загрузки
    if [[ -f "$CONFIG_FILE" ]]; then
        # Проверяем DOMAIN
        if [[ -n "$ARG_DOMAIN" ]]; then
            DOMAIN="$ARG_DOMAIN"
            if grep -q "^DOMAIN=" "$CONFIG_FILE"; then
                sed -i "s|^DOMAIN=.*|DOMAIN=\"$DOMAIN\"|" "$CONFIG_FILE"
            else
                sed -i "9a DOMAIN=\"$DOMAIN\"" "$CONFIG_FILE"
            fi
        elif ! grep -q "^DOMAIN=" "$CONFIG_FILE"; then
            print_warning "Параметр DOMAIN отсутствует в конфигурации"
            read -p "Введите доменное имя сервера (например, example.com): " DOMAIN </dev/tty
            sed -i "9a DOMAIN=\"$DOMAIN\"" "$CONFIG_FILE"
        elif grep -q "^DOMAIN=\"\"" "$CONFIG_FILE" || grep -q "^DOMAIN=''$" "$CONFIG_FILE" || grep -q "^DOMAIN=$" "$CONFIG_FILE"; then
            print_warning "Параметр DOMAIN пустой"
            read -p "Введите доменное имя сервера (например, example.com): " DOMAIN </dev/tty
            sed -i "s|^DOMAIN=.*|DOMAIN=\"$DOMAIN\"|" "$CONFIG_FILE"
        fi
        
        # Определяем внешний IP автоматически
        DETECTED_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || curl -s --max-time 5 icanhazip.com 2>/dev/null || echo "")

        # Проверяем SERVER_IP
        if [[ -n "$ARG_SERVER_IP" ]]; then
            # Параметр передан явно
            SERVER_IP="$ARG_SERVER_IP"
            if grep -q "^SERVER_IP=" "$CONFIG_FILE"; then
                sed -i "s|^SERVER_IP=.*|SERVER_IP=\"$SERVER_IP\"|" "$CONFIG_FILE"
            else
                sed -i "12a SERVER_IP=\"$SERVER_IP\"" "$CONFIG_FILE"
            fi
        elif [[ -v ARG_SERVER_IP ]]; then
            # Параметр передан как пустой --ip=""
            SERVER_IP="$DETECTED_IP"
            if grep -q "^SERVER_IP=" "$CONFIG_FILE"; then
                sed -i "s|^SERVER_IP=.*|SERVER_IP=\"$SERVER_IP\"|" "$CONFIG_FILE"
            else
                sed -i "12a SERVER_IP=\"$SERVER_IP\"" "$CONFIG_FILE"
            fi
        elif ! grep -q "^SERVER_IP=" "$CONFIG_FILE"; then
            print_warning "Параметр SERVER_IP отсутствует в конфигурации"
            read -p "Введите внешний IP-адрес сервера [${DETECTED_IP}]: " SERVER_IP </dev/tty
            SERVER_IP="${SERVER_IP:-$DETECTED_IP}"
            if [[ -n "$SERVER_IP" ]]; then
                sed -i "12a SERVER_IP=\"$SERVER_IP\"" "$CONFIG_FILE"
            fi
        elif grep -q "^SERVER_IP=\"\"" "$CONFIG_FILE" || grep -q "^SERVER_IP=''$" "$CONFIG_FILE" || grep -q "^SERVER_IP=$" "$CONFIG_FILE"; then
            SERVER_IP="$DETECTED_IP"
            sed -i "s|^SERVER_IP=.*|SERVER_IP=\"$SERVER_IP\"|" "$CONFIG_FILE"
        fi

        # Формируем email по умолчанию
        DEFAULT_ADMIN_EMAIL="admin@${DOMAIN}"

        # Проверяем ADMIN_EMAIL
        if [[ -n "$ARG_ADMIN_EMAIL" ]]; then
            # Параметр передан явно
            ADMIN_EMAIL="$ARG_ADMIN_EMAIL"
            if grep -q "^ADMIN_EMAIL=" "$CONFIG_FILE"; then
                sed -i "s|^ADMIN_EMAIL=.*|ADMIN_EMAIL=\"$ADMIN_EMAIL\"|" "$CONFIG_FILE"
            else
                sed -i "22a ADMIN_EMAIL=\"$ADMIN_EMAIL\"" "$CONFIG_FILE"
            fi
        elif [[ -v ARG_ADMIN_EMAIL ]]; then
            # Параметр передан как пустой --email=""
            ADMIN_EMAIL="$DEFAULT_ADMIN_EMAIL"
            if grep -q "^ADMIN_EMAIL=" "$CONFIG_FILE"; then
                sed -i "s|^ADMIN_EMAIL=.*|ADMIN_EMAIL=\"$ADMIN_EMAIL\"|" "$CONFIG_FILE"
            else
                sed -i "22a ADMIN_EMAIL=\"$ADMIN_EMAIL\"" "$CONFIG_FILE"
            fi
        elif ! grep -q "^ADMIN_EMAIL=" "$CONFIG_FILE"; then
            print_warning "Параметр ADMIN_EMAIL отсутствует в конфигурации"
            read -p "Введите email администратора [${DEFAULT_ADMIN_EMAIL}]: " ADMIN_EMAIL </dev/tty
            ADMIN_EMAIL="${ADMIN_EMAIL:-$DEFAULT_ADMIN_EMAIL}"
            sed -i "22a ADMIN_EMAIL=\"$ADMIN_EMAIL\"" "$CONFIG_FILE"
        elif grep -q "^ADMIN_EMAIL=\"\"" "$CONFIG_FILE" || grep -q "^ADMIN_EMAIL=''$" "$CONFIG_FILE" || grep -q "^ADMIN_EMAIL=$" "$CONFIG_FILE"; then
            ADMIN_EMAIL="$DEFAULT_ADMIN_EMAIL"
            sed -i "s|^ADMIN_EMAIL=.*|ADMIN_EMAIL=\"$ADMIN_EMAIL\"|" "$CONFIG_FILE"
        fi
        
        # Проверяем ADMIN_PASSWORD
        if [[ -n "$ARG_ADMIN_PASSWORD" ]]; then
            ADMIN_PASSWORD="$ARG_ADMIN_PASSWORD"
            if grep -q "^ADMIN_PASSWORD=" "$CONFIG_FILE"; then
                sed -i "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=\"$ADMIN_PASSWORD\"|" "$CONFIG_FILE"
            else
                sed -i "19a ADMIN_PASSWORD=\"$ADMIN_PASSWORD\"" "$CONFIG_FILE"
            fi
        elif ! grep -q "^ADMIN_PASSWORD=" "$CONFIG_FILE"; then
            print_warning "Параметр ADMIN_PASSWORD отсутствует в конфигурации"
            while true; do
                read -sp "Введите пароль администратора: " ADMIN_PASSWORD </dev/tty
                echo
                read -sp "Повторите пароль: " ADMIN_PASSWORD_CONFIRM </dev/tty
                echo
                if [[ "$ADMIN_PASSWORD" == "$ADMIN_PASSWORD_CONFIRM" ]]; then
                    break
                else
                    print_error "Пароли не совпадают. Попробуйте снова."
                fi
            done
            sed -i "19a ADMIN_PASSWORD=\"$ADMIN_PASSWORD\"" "$CONFIG_FILE"
        elif grep -q "^ADMIN_PASSWORD=\"\"" "$CONFIG_FILE" || grep -q "^ADMIN_PASSWORD=''$" "$CONFIG_FILE" || grep -q "^ADMIN_PASSWORD=$" "$CONFIG_FILE"; then
            print_warning "Параметр ADMIN_PASSWORD пустой"
            while true; do
                read -sp "Введите пароль администратора: " ADMIN_PASSWORD </dev/tty
                echo
                read -sp "Повторите пароль: " ADMIN_PASSWORD_CONFIRM </dev/tty
                echo
                if [[ "$ADMIN_PASSWORD" == "$ADMIN_PASSWORD_CONFIRM" ]]; then
                    break
                else
                    print_error "Пароли не совпадают. Попробуйте снова."
                fi
            done
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

    # Установка уровня логирования
    [[ "$DEBUG_MODE" == "true" ]] && set_log_level "DEBUG"

    # Теперь LOG_FILE и LOG_LEVEL из main.conf доступны
    init_logging

    log_info "Установка начата"
    [[ "$BACKGROUND_MODE" == "true" ]] && log_info "Режим: фоновая установка"
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
            if LOG_DIR="$LOG_DIR" LOG_FILE="$LOG_FILE" LOG_LEVEL="$LOG_LEVEL" ENABLE_LOG_FILE="$ENABLE_LOG_FILE" bash "$MODULES_DIR/$module"; then
                log_module_done "$module"
                ((executed++))
            else
                log_error "Ошибка модуля: $module"
                if [[ "$FORCE_MODE" != "true" ]]; then
                    print_error "Установка прервана"
                    cleanup_on_exit
                    exit 1
                fi
            fi
        fi
    done

    print_header "Установка завершена"
    print_info "Выполнено: $executed, Пропущено: $skipped"
    [[ "$DRY_RUN" == "true" ]] && print_warning "Это был dry-run"
    print_success "Сервер развёрнут!"
    
    # Добавляем пустые строки в оба лога для читаемости
    print_empty_line
    print_empty_line
    print_empty_line
    print_empty_line
    
    cleanup_on_exit
}

cleanup_on_exit() {
    # Удаление файла блокировки фонового процесса
    rm -f /tmp/installer_bg_running 2>/dev/null || true
    
    log_info "Установка завершена $(date '+%Y-%m-%d %H:%M:%S')"

    log_empty_line
    log_empty_line
    log_empty_line
    log_empty_line
}

main() {
    # Сохранение оригинальных аргументов для перезапуска в фоне
    ORIGINAL_ARGS=("$@")
    
    parse_args "$@"
    
    # Обработка фонового режима СРАЗУ после parse_args, ДО initialize
    if [[ "$BACKGROUND_MODE" == "true" ]] && [[ "$NO_DETACH" == "false" ]]; then
        # Проверка, не запущен ли уже процесс установки
        if [[ -f "/tmp/installer_bg_running" ]]; then
            print_error "Установка уже запущена в фоновом режиме"
            print_info "PID: $(cat /tmp/installer_bg_running 2>/dev/null || echo 'неизвестен')"
            exit 1
        fi
        
        # Загружаем конфиг для получения LOG_DIR
        [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE" 2>/dev/null || true

        # Пересчитываем LOG_DIR после загрузки конфига
        if [[ -z "${LOG_DIR+x}" ]] || [[ -z "${LOG_DIR}" ]]; then
            LOG_DIR="$PROJECT_DIR/logs"
        elif [[ "${LOG_DIR}" != /* ]]; then
            # Если путь относительный (не начинается с /), делаем его относительно PROJECT_DIR
            LOG_DIR="$PROJECT_DIR/${LOG_DIR}"
        fi
        # Создаем директорию для логов
        mkdir -p "$LOG_DIR" 2>/dev/null || true
        export LOG_DIR

        echo ""
        print_info "Запуск установки в фоновом режиме..."
        print_info "Лог событий: ${LOG_DIR}/${LOG_FILE:-install.log}"
        print_info "Лог консоли: ${LOG_DIR}/${CONSOLE_LOG_FILE:-console.log}"
        echo ""
        print_info "Для просмотра логов в реальном времени используйте:"
        print_step "tail -f ${LOG_DIR}/${CONSOLE_LOG_FILE:-console.log}"
        echo ""
        
        # Запуск в фоне с nohup
        touch /tmp/installer_bg_running
        setsid "$0" "${ORIGINAL_ARGS[@]}" --no-detach </dev/null >>"${LOG_DIR}/${CONSOLE_LOG_FILE:-console.log}" 2>&1 &
        BACKGROUND_PID=$!
        echo "$BACKGROUND_PID" > /tmp/installer_bg_running
        
        print_success "Установка запущена в фоне (PID: $BACKGROUND_PID)"
        print_info "Вы можете закрыть эту сессию, установка продолжится в фоне"
        echo ""
        
        exit 0
    fi
    
    # При --no-detach гарантируем install.log; дубли console.log отключает print.sh ([[ ! -t 1 ]])
    if [[ "$NO_DETACH" == "true" ]]; then
        export ENABLE_LOG_FILE=true
    fi
    
    initialize
    run_installation
}

main "$@"
