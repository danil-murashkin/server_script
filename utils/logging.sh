#!/bin/bash
# utils/logging.sh - Логирование
# Часть Git Server Deployment Module System

# Цвета (если ещё не загружены)
if [[ -z "${COLORS[BOLD]}" ]] && [[ -f "$(dirname "${BASH_SOURCE[0]}")/colors.sh" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/colors.sh"
fi

UTIL_LOGGING_LOADED=true

# Определяем директорию скрипта
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Функция для инициализации LOG_DIR (вызывается при init_logging)
_init_log_dir() {
    if [[ -z "${LOG_DIR+x}" ]] || [[ -z "${LOG_DIR}" ]]; then
        LOG_DIR="$SCRIPT_DIR/logs"
    elif [[ "${LOG_DIR}" != /* ]]; then
        # Если путь относительный (не начинается с /), делаем его относительно SCRIPT_DIR
        LOG_DIR="$SCRIPT_DIR/${LOG_DIR}"
    fi
    # Создаем директорию для логов если её нет
    mkdir -p "$LOG_DIR" 2>/dev/null || true
}

: "${LOG_FILE:=install.log}"
: "${LOG_LEVEL:=INFO}"
: "${ENABLE_LOG_FILE:=true}"

init_logging() {
    [[ "${ENABLE_LOG_FILE}" != "true" ]] && return 0
    
    _init_log_dir

    local log_path
    if [[ -z "${LOG_DIR}" ]]; then
        log_path="${LOG_FILE}"
    else
        log_path="${LOG_DIR}/${LOG_FILE}"
        [[ ! -d "${LOG_DIR}" ]] && mkdir -p "${LOG_DIR}" 2>/dev/null || true
    fi
    
    {
        echo "========================================"
        echo "Server Installer Log"
        echo "Start time: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Log level: $LOG_LEVEL"
        echo "========================================"
    } >> "$log_path" 2>/dev/null || true

    _write_log "INFO" "Логирование инициализировано"
}

_write_log() {
    local level="$1"
    local message="$2"
    
    # Проверка включено ли логирование
    [[ "${ENABLE_LOG_FILE:-true}" != "true" ]] && return 0
    
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Проверка уровня
    case "$LOG_LEVEL" in
        "DEBUG") enabled=("DEBUG" "INFO" "WARN" "ERROR") ;;
        "INFO")  enabled=("INFO" "WARN" "ERROR") ;;
        "WARN")  enabled=("WARN" "ERROR") ;;
        "ERROR") enabled=("ERROR") ;;
        *)       enabled=("INFO" "WARN" "ERROR") ;;
    esac

    local log_enabled=false
    for lvl in "${enabled[@]}"; do
        [[ "$lvl" == "$level" ]] && log_enabled=true && break
    done

    if [[ "$log_enabled" == "true" ]]; then
        local log_path
        if [[ -z "${LOG_DIR}" ]]; then
            log_path="${LOG_FILE}"
        else
            log_path="${LOG_DIR}/${LOG_FILE}"
            [[ ! -d "${LOG_DIR}" ]] && mkdir -p "${LOG_DIR}" 2>/dev/null || true
        fi
        printf "[%s] [%-7s] %s\n" "$timestamp" "$level" "$message" >> "$log_path" 2>/dev/null || true
    fi
}

log_info()    { _write_log "INFO"    "$*"; }
log_warn()    { _write_log "WARN"    "$*"; }
log_warning() { _write_log "WARN"    "$*"; }
log_error()   { _write_log "ERROR"   "$*"; }
log_debug()   { [[ "$LOG_LEVEL" == "DEBUG" ]] && _write_log "DEBUG" "$*"; }

# Функция для записи пустой строки в лог событий
log_empty_line() {
    [[ "${ENABLE_LOG_FILE:-true}" != "true" ]] && return 0
    local log_path
    if [[ -z "${LOG_DIR}" ]]; then
        log_path="${LOG_FILE}"
    else
        log_path="${LOG_DIR}/${LOG_FILE}"
    fi
    echo "" >> "$log_path" 2>/dev/null || true
}

set_log_level() {
    case "${1^^}" in
        "DEBUG"|"INFO"|"WARN"|"WARNING"|"ERROR")
            LOG_LEVEL="${1^^}"
            [[ "$LOG_LEVEL" == "WARNING" ]] && LOG_LEVEL="WARN"
            _write_log "INFO" "Уровень логирования: $LOG_LEVEL"
            ;;
    esac
}

log_module_start() {
    print_header "Запуск модуля: $1"
    _write_log "INFO" "┌──────────────────────────────────────────────────"
    _write_log "INFO" "│ START MODULE: $1"
    _write_log "INFO" "└──────────────────────────────────────────────────"
}

log_module_done() {
    print_success "Модуль завершён: $1"
    _write_log "INFO" "┌──────────────────────────────────────────────────"
    _write_log "INFO" "│ MODULE COMPLETED: $1"
    _write_log "INFO" "└──────────────────────────────────────────────────"
}
