#!/bin/bash

# modules/02-basic-software.sh - Установка базового ПО
# Часть Git Server Deployment Module System

[[ -z "${UTIL_PRINT_LOADED}" ]] && source ./utils/print.sh 2>/dev/null
[[ -z "${UTIL_LOGGING_LOADED}" ]] && source ./utils/logging.sh 2>/dev/null
[[ -z "${UTIL_FUNCTIONS_LOADED}" ]] && source ./utils/functions.sh 2>/dev/null


print_step "Информация о системе"
log_info "ОС: $(lsb_release -sd)"
log_info "Версия: $(lsb_release -r)"
print_info "ОС: $(lsb_release -sd)"
print_info "Версия: $(lsb_release -r)"

print_step "Использование диска"
df -h / | tail -n +2 | while read line; do
    print_info "$line"
    log_info "Disk usage: $line"
done

print_step "Обновление системы"
if [[ "$DRY_RUN" == "true" ]]; then
    print_warn "(DRY RUN) Пропущено: apt update && apt upgrade"
    log_info "[DRY RUN] Пропущено: обновление системы"
else
    print_info "Выполняется: apt update && apt upgrade"
    log_info "Запуск: apt update && apt upgrade"
    if apt update -qq && apt upgrade -y >/dev/null 2>&1; then
        print_success "Система обновлена"
        log_info "Система успешно обновлена"
    else
        print_error "Ошибка при обновлении системы"
        log_error "apt upgrade failed"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
fi

print_step "Установка базовых утилит"
essential_tools=(
    nano
    curl
    wget
    sudo
    net-tools
    bash-completion
    lsof
    perl
    gnupg
    unzip
)

tools_str="${essential_tools[*]}"

if [[ "$DRY_RUN" == "true" ]]; then
    print_warn "(DRY RUN) Установка: $tools_str"
    log_info "[DRY RUN] Установка пакетов: $tools_str"
else
    print_info "Установка: $tools_str"
    log_info "Установка базовых утилит: $tools_str"
    if apt install -y "${essential_tools[@]}" >/dev/null 2>&1; then
        print_success "Базовые утилиты установлены"
        log_info "Базовые утилиты установлены: ${#essential_tools[@]} шт."
    else
        print_error "Ошибка при установке утилит"
        log_error "Не удалось установить базовые утилиты"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
fi
