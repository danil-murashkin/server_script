#!/bin/bash

# utils/print.sh - Утилита для цветного вывода в терминале
# Часть Git Server Deployment Module System

UTIL_PRINT_LOADED=true

# Определяем директорию скрипта
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Функция для инициализации LOG_DIR (вызывается после загрузки конфига)
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

: "${CONSOLE_LOG_FILE:=console.log}"
: "${ENABLE_CONSOLE_LOG:=false}"

# ANSI цветовые коды
declare -A COLORS=(
    # Основные цвета
    ["BLACK"]="\033[0;30m"
    ["RED"]="\033[0;31m"
    ["GREEN"]="\033[0;32m"
    ["YELLOW"]="\033[0;33m"
    ["BLUE"]="\033[38;5;111m"
    ["PURPLE"]="\033[0;35m"
    ["CYAN"]="\033[0;36m"
    ["WHITE"]="\033[0;37m"
    
    # Яркие цвета
    ["BRIGHT_BLACK"]="\033[1;30m"
    ["BRIGHT_RED"]="\033[1;31m"
    ["BRIGHT_GREEN"]="\033[1;32m"
    ["BRIGHT_YELLOW"]="\033[1;33m"
    ["BRIGHT_BLUE"]="\033[38;5;117m"
    ["BRIGHT_PURPLE"]="\033[1;35m"
    ["BRIGHT_CYAN"]="\033[1;36m"
    ["BRIGHT_WHITE"]="\033[1;37m"
    
    # Стили
    ["BOLD"]="\033[1m"
    ["DIM"]="\033[2m"
    ["UNDERLINE"]="\033[4m"
    ["REVERSE"]="\033[7m"
    
    # Сброс
    ["RESET"]="\033[0m"
    ["NC"]="\033[0m"  # No Color
)

# Функция для проверки поддержки цветов
supports_color() {
    if [[ -t 1 ]] && [[ "${TERM:-}" != "dumb" ]] && command -v tput >/dev/null 2>&1; then
        if tput colors >/dev/null 2>&1 && [[ $(tput colors) -ge 8 ]]; then
            return 0
        fi
    fi
    return 1
}

# Глобальная переменная для управления цветами
USE_COLORS=${USE_COLORS:-true}

# Функция для получения цвета
get_color() {
    local color_name="$1"
    if [[ "$USE_COLORS" == "true" ]] && supports_color; then
        echo -e "${COLORS[$color_name]:-}"
    fi
}

# Запись в консольный лог (без цветов)
# Если stdout не TTY (фоновый >>console.log, pipe, модуль под bash), echo уже попадает в лог;
# main.conf с ENABLE_CONSOLE_LOG=true иначе дублировал бы каждую строку.
_write_console_log() {
    [[ "${ENABLE_CONSOLE_LOG:-false}" != "true" ]] && return 0
    [[ ! -t 1 ]] && return 0

    # Инициализируем LOG_DIR если ещё не инициализирована
    [[ -z "${LOG_DIR}" ]] && _init_log_dir
    
    local message="$1"
    local console_path
    
    if [[ -z "${LOG_DIR}" ]]; then
        console_path="${CONSOLE_LOG_FILE}"
    else
        console_path="${LOG_DIR}/${CONSOLE_LOG_FILE}"
        [[ ! -d "${LOG_DIR}" ]] && mkdir -p "${LOG_DIR}" 2>/dev/null || true
    fi
    
    # Удаление ANSI escape-последовательностей для чистого текста
    local clean_message=$(echo -e "$message" | sed 's/\x1b\[[0-9;]*m//g')
    echo "$clean_message" >> "$console_path" 2>/dev/null || true
}

# Функция для цветного вывода
print_color() {
    local color="$1"
    shift
    local message="$*"
    
    if [[ "$USE_COLORS" == "true" ]] && supports_color; then
        echo -e "${COLORS[$color]:-}${message}${COLORS[RESET]}"
        _write_console_log "${COLORS[$color]:-}${message}${COLORS[RESET]}"
    else
        echo "$message"
        _write_console_log "$message"
    fi
}

# Предопределенные функции для часто используемых цветов
print_success() {
    local msg="✅ $*"
    print_color "BRIGHT_GREEN" "$msg"
}

print_error() {
    local msg="❌ $*"
    print_color "BRIGHT_RED" "$msg"
}

print_warning() {
    local msg="⚠️  $*"
    print_color "BRIGHT_YELLOW" "$msg"
}

print_info() {
    local msg="ℹ️  $*"
    print_color "BRIGHT_BLUE" "$msg"
}

print_debug() {
    local msg="🔍 DEBUG: $*"
    print_color "DIM" "$msg"
}

print_header() {
    local msg="
================================================================================
$*
================================================================================"
    print_color "BOLD" "$msg"
}

print_section() {
    local msg="
--- $* ---"
    print_color "BRIGHT_CYAN" "$msg"
}

print_step() {
    local msg="➤ $*"
    print_color "PURPLE" "$msg"
}

# Функция для записи пустой строки в консольный лог
print_empty_line() {
    echo ""
    [[ "${ENABLE_CONSOLE_LOG:-false}" != "true" ]] && return 0
    [[ ! -t 1 ]] && return 0

    local console_path
    if [[ -z "${LOG_DIR}" ]]; then
        console_path="${CONSOLE_LOG_FILE}"
    else
        console_path="${LOG_DIR}/${CONSOLE_LOG_FILE}"
    fi
    echo "" >> "$console_path" 2>/dev/null || true
}

# Функция для прогресс-бара
print_progress() {
    local current="$1"
    local total="$2"
    local width=50
    local percentage=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))
    
    local bar=""
    for ((i=0; i<filled; i++)); do
        bar+="█"
    done
    for ((i=0; i<empty; i++)); do
        bar+="░"
    done
    
    local msg="Progress: [$bar] $percentage% ($current/$total)"
    printf "\r${COLORS[BRIGHT_BLUE]}%s${COLORS[RESET]}" "$msg"
    _write_console_log "$msg"
    
    if [[ "$current" -eq "$total" ]]; then
        echo ""
        _write_console_log ""
    fi
}

# Функция для создания разделителя
print_separator() {
    local char="${1:-─}"
    local length="${2:-80}"
    
    local separator=""
    for ((i=0; i<length; i++)); do
        separator+="$char"
    done
    
    print_color "DIM" "$separator"
}

# Функция для вывода с timestamp
print_timestamp() {
    local color="$1"
    shift
    local message="$*"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    print_color "$color" "[$timestamp] $message"
}

# Функция для вывода статуса операции
print_status() {
    local status="$1"
    local message="$2"
    
    case "$status" in
        "OK"|"SUCCESS"|"DONE")
            print_color "BRIGHT_GREEN" "[  OK  ] $message"
            ;;
        "ERROR"|"FAIL"|"FAILED")
            print_color "BRIGHT_RED" "[ FAIL ] $message"
            ;;
        "WARN"|"WARNING")
            print_color "BRIGHT_YELLOW" "[ WARN ] $message"
            ;;
        "INFO")
            print_color "BRIGHT_BLUE" "[ INFO ] $message"
            ;;
        "SKIP"|"SKIPPED")
            print_color "DIM" "[ SKIP ] $message"
            ;;
        *)
            print_color "WHITE" "[ $status ] $message"
            ;;
    esac
}

# Функция для интерактивного запроса с цветом
ask_question() {
    local question="$1"
    local default="${2:-}"
    
    if [[ -n "$default" ]]; then
        print_color "BRIGHT_YELLOW" "$question [default: $default]: "
    else
        print_color "BRIGHT_YELLOW" "$question: "
    fi
    
    read -r answer
    echo "${answer:-$default}"
}

# Функция для отключения цветов
disable_colors() {
    USE_COLORS=false
}

# Функция для включения цветов
enable_colors() {
    USE_COLORS=true
}
