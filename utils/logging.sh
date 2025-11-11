#!/bin/bash
# utils/logging.sh - Логирование
# Часть Git Server Deployment Module System

# Цвета (если ещё не загружены)
if [[ -z "${COLORS[BOLD]}" ]] && [[ -f "$(dirname "${BASH_SOURCE[0]}")/colors.sh" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/colors.sh"
fi

UTIL_LOGGING_LOADED=true

# Значения по умолчанию (если не заданы в конфиге)
: "${LOG_FILE:=${HOME:-/root}/server-installer.log}"
: "${LOG_LEVEL:=INFO}"
: "${QUIET_MODE:=false}"



init_logging() {
    {
        echo "========================================"
        echo "Server Installer Log"
        echo "Start time: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Log level: $LOG_LEVEL"
        echo "Quiet mode: $QUIET_MODE"
        echo "========================================"
    } >> "$LOG_FILE" 2>/dev/null || true

    log_info "Логирование инициализировано"
}

_write_log() {
    local level="$1"
    local message="$2"
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
        # ⚠️ Никакого вывода в консоль!
        printf "[%s] [%-7s] %s\n" "$timestamp" "$level" "$message" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

log_info()    { _write_log "INFO"    "$*"; }
log_warn()    { _write_log "WARN"    "$*"; }
log_warning() { _write_log "WARN"    "$*"; }
log_error()   { _write_log "ERROR"   "$*"; }
log_debug()   { [[ "$LOG_LEVEL" == "DEBUG" ]] && _write_log "DEBUG" "$*"; }

set_log_level() {
    case "${1^^}" in
        "DEBUG"|"INFO"|"WARN"|"WARNING"|"ERROR")
            LOG_LEVEL="${1^^}"
            [[ "$LOG_LEVEL" == "WARNING" ]] && LOG_LEVEL="WARN"
            log_info "Уровень логирования: $LOG_LEVEL"
            ;;
    esac
}

enable_quiet_mode() { QUIET_MODE=true; log_info "Тихий режим включён"; }
disable_quiet_mode(){ QUIET_MODE=false; }

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
