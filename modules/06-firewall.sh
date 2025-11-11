#!/bin/bash
# modules/06-firewall.sh - Настройка UFW firewall
# Часть Mail Server Deployment Module System

# Загрузка утилит (если ещё не загружены)
[[ -z "${UTIL_PRINT_LOADED}" ]] && source ./utils/print.sh 2>/dev/null
[[ -z "${UTIL_LOGGING_LOADED}" ]] && source ./utils/logging.sh 2>/dev/null
[[ -z "${UTIL_FUNCTIONS_LOADED}" ]] && source ./utils/functions.sh 2>/dev/null


# --- Загружаем конфиг, если нужно ---
load_config || {
    print_error "Не удалось загрузить конфигурацию. Убедитесь, что ./config/main.conf существует и содержит DOMAIN, SERVER_IP."
    log_error "Failed to load required configuration"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
}

# --- Проверка: установлен ли UFW? ---
print_step "Проверка наличия UFW"
if ! command -v ufw &> /dev/null; then
    print_info "UFW не установлен — устанавливаем..."
    apt update -qq >/dev/null 2>&1
    if apt install -y ufw > /dev/null 2>&1; then
        print_success "UFW успешно установлен"
        log_info "UFW installed successfully"
    else
        print_error "Не удалось установить UFW"
        log_error "Failed to install UFW"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
else
    print_success "UFW уже установлен"
    log_info "UFW is already installed"
fi

# --- Проверка: разрешён ли SSH? ---
print_step "Проверка правил для SSH"
SSH_ALLOWED=false

# Проверяем, есть ли правило для OpenSSH или порта 22
if ufw status | grep -q "OpenSSH\|22/tcp"; then
    SSH_ALLOWED=true
    print_success "SSH уже разрешён"
    log_info "SSH is already allowed"
fi

# Если SSH не разрешён — добавляем правило
if [[ "$SSH_ALLOWED" == "false" ]]; then
    print_info "Разрешаем SSH (OpenSSH)..."
    if ufw allow OpenSSH > /dev/null 2>&1; then
        print_success "SSH разрешён"
        log_info "SSH access allowed via 'ufw allow OpenSSH'"
        SSH_ALLOWED=true
    else
        print_error "Не удалось разрешить SSH"
        log_error "Failed to allow SSH"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
fi

# --- Включение UFW ---
print_step "Включение UFW (политика по умолчанию: deny incoming)"
if [[ "$SSH_ALLOWED" == "false" ]] && [[ "$FORCE_MODE" != "true" ]]; then
    print_error "Опасная операция: SSH не разрешён. Включение UFW может привести к потере доступа!"
    log_error "Refusing to enable UFW: SSH is not allowed and FORCE_MODE=false"
    exit 1
fi

# Включаем UFW с флагом --force, чтобы не было интерактивного подтверждения
if ufw --force enable > /dev/null 2>&1; then
    print_success "🔥 UFW успешно включён"
    log_info "UFW enabled successfully"
else
    print_error "Не удалось включить UFW"
    log_error "Failed to enable UFW"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# --- Отображение текущего статуса ---
print_step "Текущий статус UFW:"
ufw status
log_info "UFW status displayed"
