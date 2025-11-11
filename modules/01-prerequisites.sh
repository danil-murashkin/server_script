#!/bin/bash

# modules/01-prerequisites.sh - Проверка системы
# Часть Git Server Deployment Module System

# === Проверка root — СРАЗУ и ПЕРВОЙ ===
if [[ $EUID -ne 0 ]]; then
    # Используем цвета из colors.sh, если доступны
    if [[ -f "./utils/colors.sh" ]]; then
        source "./utils/colors.sh" && print_error "Требуется запуск от root"
    else
        RED="\033[31m"
        NC="\033[0m"
        echo -e "${RED}ERROR: Please, run script under root${NC}"
    fi
    exit 1
fi


[[ -z "${UTIL_PRINT_LOADED}" ]] && source ./utils/print.sh 2>/dev/null
[[ -z "${UTIL_LOGGING_LOADED}" ]] && source ./utils/logging.sh 2>/dev/null
[[ -z "${UTIL_FUNCTIONS_LOADED}" ]] && source ./utils/functions.sh 2>/dev/null


print_step "Проверка ОС: Debian 11+"
if ! grep -q "Debian" /etc/os-release 2>/dev/null; then
    print_error "Поддерживается только Debian"
    exit 1
fi

version=$(grep VERSION_ID /etc/os-release | cut -d'"' -f2 | cut -d. -f1)
if [[ "$version" -lt 11 ]]; then
    print_error "Требуется Debian 11+, найдено: $version"
    exit 1
fi

print_step "Проверка места на диске (минимум 2 ГБ)"
min_space_kb=$((2 * 1024 * 1024))
free_space=$(df / --output=avail -k | tail -n1 | tr -d ' ')

if [[ "$free_space" -lt "$min_space_kb" ]]; then
    print_error "Недостаточно места: требуется минимум 2 ГБ, доступно: $((free_space / 1024)) МБ"
    exit 1
fi

print_step "Обновление пакетов"
apt update -qq >/dev/null && print_success "OK" || {
    print_error "Не удалось обновить пакеты"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
}
