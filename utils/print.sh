#!/bin/bash

# utils/print.sh - Утилита для цветного вывода в терминале
# Часть Git Server Deployment Module System

UTIL_PRINT_LOADED=true

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

# Функция для цветного вывода
print_color() {
    local color="$1"
    shift
    local message="$*"
    
    if [[ "$USE_COLORS" == "true" ]] && supports_color; then
        echo -e "${COLORS[$color]:-}${message}${COLORS[RESET]}"
    else
        echo "$message"
    fi
}

# Предопределенные функции для часто используемых цветов
print_success() {
    print_color "BRIGHT_GREEN" "✅ $*"
}

print_error() {
    print_color "BRIGHT_RED" "❌ $*"
}

print_warning() {
    print_color "BRIGHT_YELLOW" "⚠️  $*"
}

print_info() {
    print_color "BRIGHT_BLUE" "ℹ️  $*"
}

print_debug() {
    print_color "DIM" "🔍 DEBUG: $*"
}

print_header() {
    print_color "BOLD" "
================================================================================
$*
================================================================================"
}

print_section() {
    print_color "BRIGHT_CYAN" "
--- $* ---"
}

print_step() {
    print_color "PURPLE" "➤ $*"
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
    
    printf "\r${COLORS[BRIGHT_BLUE]}Progress: [%s] %d%% (%d/%d)${COLORS[RESET]}" \
        "$bar" "$percentage" "$current" "$total"
    
    if [[ "$current" -eq "$total" ]]; then
        echo ""
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

# Функции для логирования с временными метками
log_success() {
    print_timestamp "BRIGHT_GREEN" "✅ SUCCESS: $*"
}

log_error() {
    print_timestamp "BRIGHT_RED" "❌ ERROR: $*"
}

log_warning() {
    print_timestamp "BRIGHT_YELLOW" "⚠️  WARNING: $*"
}

log_info() {
    print_timestamp "BRIGHT_BLUE" "ℹ️  INFO: $*"
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

# Функция для демонстрации всех цветов
show_colors() {
    echo "Демонстрация цветов:"
    echo
    
    for color in "${!COLORS[@]}"; do
        if [[ "$color" != "RESET" && "$color" != "NC" ]]; then
            print_color "$color" "$color: Пример текста"
        fi
    done
    
    echo
    echo "Предопределенные функции:"
    print_success "Успешное выполнение"
    print_error "Ошибка выполнения"
    print_warning "Предупреждение"
    print_info "Информация"
    print_debug "Отладочная информация"
    print_step "Шаг выполнения"
    
    print_header "Заголовок раздела"
    print_section "Подраздел"
    print_separator
    
    print_status "OK" "Операция выполнена успешно"
    print_status "ERROR" "Произошла ошибка"
    print_status "WARN" "Внимание"
    
    echo
    echo "Прогресс-бар:"
    for i in {1..10}; do
        print_progress "$i" 10
        sleep 0.1
    done
}

# Если скрипт запущен напрямую, показать демонстрацию
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        "demo"|"show"|"test")
            show_colors
            ;;
        "disable")
            echo "Цвета отключены"
            disable_colors
            ;;
        "enable")
            echo "Цвета включены"
            enable_colors
            ;;
        *)
            echo "Использование: $0 [demo|show|test|enable|disable]"
            echo "  demo/show/test - показать демонстрацию цветов"
            echo "  enable         - включить цвета"
            echo "  disable        - отключить цвета"
            echo
            echo "Или подключите как библиотеку:"
            echo "  source $0"
            ;;
    esac
fi
