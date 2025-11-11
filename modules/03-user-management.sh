#!/bin/bash

# modules/03-user-management.sh - Создание пользователей и настройка доступа
# Часть Git Server Deployment Module System

[[ -z "${UTIL_PRINT_LOADED}" ]] && source ./utils/print.sh 2>/dev/null
[[ -z "${UTIL_LOGGING_LOADED}" ]] && source ./utils/logging.sh 2>/dev/null
[[ -z "${UTIL_FUNCTIONS_LOADED}" ]] && source ./utils/functions.sh 2>/dev/null


# Значения по умолчанию
: "${ADMIN_USER:=webadmin}"
: "${ADMIN_PASSWORD:=}"
: "${ADMIN_SSH_KEY:=}"
: "${ADMIN_GROUPS:=sudo}"
: "${DISABLE_ROOT_SSH:=false}"

HOME_DIR="/home/$ADMIN_USER"
SUDOERS_FILE="/etc/sudoers.d/$ADMIN_USER"

# Включаем строгий режим ПОСЛЕ объявления переменных
set -uo pipefail  # ← убираем 'e', чтобы контролировать ошибки вручную

log_info "Начало настройки пользователей: $ADMIN_USER"

# --- Проверка: пользователь уже существует? ---
if id "$ADMIN_USER" &>/dev/null; then
    log_warning "Пользователь $ADMIN_USER уже существует — обновляем конфигурацию"
else
    log_info "Создаём пользователя: $ADMIN_USER"
    if useradd -m -s /bin/bash "$ADMIN_USER"; then
        log_success "Пользователь $ADMIN_USER создан"
    else
        log_error "Не удалось создать пользователя: $ADMIN_USER"
        exit 1
    fi
fi

# --- Проверка домашней директории ---
if [[ ! -d "$HOME_DIR" ]]; then
    log_error "Домашняя директория $HOME_DIR не существует"
    exit 1
fi

# --- Установка прав на домашнюю директорию (без -R, если не нужно) ---
# Только если владелец не тот
if [[ "$(stat -c '%U:%G' "$HOME_DIR")" != "$ADMIN_USER:$ADMIN_USER" ]]; then
    chown "$ADMIN_USER:$ADMIN_USER" "$HOME_DIR" && log_info "Владелец $HOME_DIR изменён"
fi

# Только если права не 700
if [[ "$(stat -c '%a' "$HOME_DIR")" != "700" ]]; then
    chmod 700 "$HOME_DIR" && log_info "Права $HOME_DIR изменены на 700"
fi

# --- Установка пароля (если задан) ---
if [[ -n "$ADMIN_PASSWORD" ]]; then
    log_info "Устанавливаем пароль для $ADMIN_USER"
    echo "$ADMIN_USER:$ADMIN_PASSWORD" | chpasswd || {
        log_error "Не удалось установить пароль для $ADMIN_USER"
        exit 1
    }
    log_info "Пароль установлен"
else
    log_warning "Пароль не задан — вход по SSH-ключу или sudo без пароля"
fi

# --- Настройка групп ---
log_info "Настройка групп: $ADMIN_GROUPS"
IFS=',' read -ra GROUPS <<< "$ADMIN_GROUPS"
for group in "${GROUPS[@]}"; do
    group=$(echo "$group" | xargs)
    [[ -z "$group" ]] && continue

    if ! getent group "$group" >/dev/null; then
        log_warn "Группа не существует: $group — создаём"
        groupadd "$group" || log_warn "Не удалось создать группу: $group"
    fi

    if ! id "$ADMIN_USER" | grep -q "\b$group\b"; then
        if usermod -aG "$group" "$ADMIN_USER"; then
            log_info "Пользователь добавлен в группу: $group"
        else
            log_warn "Не удалось добавить $ADMIN_USER в группу: $group"
        fi
    else
        log_info "Пользователь уже в группе: $group"
    fi
done

# --- Настройка SSH (если задан ключ) ---
if [[ -n "$ADMIN_SSH_KEY" ]]; then
    SSH_DIR="$HOME_DIR/.ssh"
    AUTH_KEYS="$SSH_DIR/authorized_keys"

    log_info "Настройка SSH-доступа для $ADMIN_USER"
    mkdir -p "$SSH_DIR"
    echo "$ADMIN_SSH_KEY" > "$AUTH_KEYS"

    chown -R "$ADMIN_USER:$ADMIN_USER" "$SSH_DIR" 2>/dev/null || \
        chown "$ADMIN_USER:$ADMIN_USER" "$SSH_DIR" && chmod 700 "$SSH_DIR"
    chmod 600 "$AUTH_KEYS" 2>/dev/null || true

    log_success "SSH-ключ добавлен для $ADMIN_USER"
else
    log_warning "SSH-ключ не задан — вход по паролю (рекомендуется добавить ключ вручную)"
fi

# --- Настройка sudo без пароля ---
if [[ ! -f "$SUDOERS_FILE" ]]; then
    echo "$ADMIN_USER ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_FILE"
    chmod 440 "$SUDOERS_FILE"
    log_info "Настроено: $ADMIN_USER может использовать sudo без пароля"
else
    log_info "Файл sudoers уже существует: $SUDOERS_FILE"
fi

# --- Отключение входа root по SSH (опционально) ---
if [[ "$DISABLE_ROOT_SSH" == "true" ]]; then
    if [[ -f /etc/ssh/sshd_config ]]; then
        log_info "Отключение входа root по SSH"
        sed -i 's/^PermitRootLogin[[:space:]]\+yes/PermitRootLogin no/g' /etc/ssh/sshd_config
        sed -i 's/^#PermitRootLogin[[:space:]]\+yes/PermitRootLogin no/g' /etc/ssh/sshd_config
        sed -i 's/^PermitRootLogin[[:space:]]\+prohibit-password/PermitRootLogin no/g' /etc/ssh/sshd_config

        print_warning "Изменён /etc/ssh/sshd_config: PermitRootLogin no"
        print_warning "Рекомендуется перезапустить SSH: systemctl restart ssh"
    else
        log_warn "/etc/ssh/sshd_config не найден — не удалось отключить root-доступ"
    fi
fi

log_success "Настройка пользователей завершена: $ADMIN_USER"
exit 0
