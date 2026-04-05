#!/bin/bash
# modules/17-proxy-socks-dante.sh - Установка и настройка SOCKS5-прокси Dante
# Часть Server Deployment Module System
# Устанавливается после Squid (HTTP proxy) для обеспечения SOCKS5 туннелирования

# --- Загрузка вспомогательных утилит ---
[[ -z "${UTIL_PRINT_LOADED}" ]] && source ./utils/print.sh 2>/dev/null
[[ -z "${UTIL_LOGGING_LOADED}" ]] && source ./utils/logging.sh 2>/dev/null
[[ -z "${UTIL_FUNCTIONS_LOADED}" ]] && source ./utils/functions.sh 2>/dev/null

# --- Проверка прав root ---
ensure_root

# --- Загружаем конфиг ---
load_config || {
    print_error "Не удалось загрузить конфигурацию"
    log_error "Failed to load configuration"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
}

# --- Проверка включения модуля ---
if [[ "${ENABLE_SOCKS_PROXY:-false}" != "true" ]]; then
    print_warning "SOCKS5 Dante отключен в конфигурации (ENABLE_SOCKS_PROXY=false)"
    log_info "SOCKS5 Dante installation skipped (ENABLE_SOCKS_PROXY=false)"
    exit 0
fi

# --- Проверка переменных ---
print_step "Проверка конфигурации SOCKS5-прокси"

SOCKS_USER="${SOCKS_USER:-socksuser}"
SOCKS_PASSWORD="${SOCKS_PASSWORD:-$ADMIN_PASSWORD}"
SOCKS_PORT="${SOCKS_PORT:-1080}"
SOCKS_SUBDOMAIN="${SOCKS_SUBDOMAIN:-proxy}"
SOCKS_URL="$SOCKS_SUBDOMAIN.$DOMAIN"

# Список учёток (системные пользователи Linux): "user:pass,user2:pass2"; пустой pass → SOCKS_PASSWORD
SOCKS_USERS_LINE="${SOCKS_DEFAULT_USERS:-${SOCKS_USER}:}"

declare -a SOCKS_ACCOUNT_NAMES=()
declare -a SOCKS_ACCOUNT_PASSWORDS=()

IFS=',' read -ra _socks_entries <<< "$SOCKS_USERS_LINE"
for _raw in "${_socks_entries[@]}"; do
    _entry="${_raw#"${_raw%%[![:space:]]*}"}"
    _entry="${_entry%"${_entry##*[![:space:]]}"}"
    [[ -z "$_entry" ]] && continue
    _name="${_entry%%:*}"
    _pass="${_entry#*:}"
    if [[ "$_name" == "$_entry" ]]; then
        _pass=""
    fi
    [[ -z "$_name" ]] && continue
    [[ -z "$_pass" ]] && _pass="$SOCKS_PASSWORD"
    SOCKS_ACCOUNT_NAMES+=("$_name")
    SOCKS_ACCOUNT_PASSWORDS+=("$_pass")
done

if [[ ${#SOCKS_ACCOUNT_NAMES[@]} -eq 0 ]]; then
    print_error "Не заданы пользователи SOCKS (SOCKS_DEFAULT_USERS / SOCKS_USER)"
    log_error "No SOCKS accounts configured"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

SOCKS_USER="${SOCKS_ACCOUNT_NAMES[0]}"

log_info "SOCKS5 прокси: $SOCKS_URL:$SOCKS_PORT"
log_info "Пользователи (${#SOCKS_ACCOUNT_NAMES[@]}): ${SOCKS_ACCOUNT_NAMES[*]}"

# --- Проверка ОС ---
ensure_debian || {
    print_error "Поддерживается только Debian 11+"
    log_error "Unsupported OS"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
}

# --- Определение сетевого интерфейса ---
print_step "Определение сетевого интерфейса"
NET_IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -1)
if [[ -z "$NET_IFACE" ]]; then
    NET_IFACE=$(ip link show | awk -F: '$0 !~ "lo|vir|docker|^[^0-9]"{print $2;exit}' | tr -d ' ')
fi
if [[ -z "$NET_IFACE" ]]; then
    print_error "Не удалось определить сетевой интерфейс"
    log_error "Could not detect network interface"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi
print_success "Сетевой интерфейс: $NET_IFACE"
log_info "Network interface: $NET_IFACE"

# --- Установка Dante ---
print_step "Установка dante-server"
if [[ "$DRY_RUN" == "true" ]]; then
    print_warn "(DRY RUN) Установка: dante-server"
    log_info "[DRY RUN] Установка пакетов"
else
    if ! dpkg -l | grep -q "^ii.*dante-server"; then
        apt update -qq >/dev/null 2>&1
        if apt install -y dante-server >/dev/null 2>&1; then
            print_success "dante-server установлен"
            log_info "dante-server installed successfully"
        else
            print_error "Ошибка установки dante-server"
            log_error "apt install dante-server failed"
            [[ "$FORCE_MODE" != "true" ]] && exit 1
        fi
    else
        print_success "dante-server уже установлен — обновление"
        log_info "dante-server already installed — upgrading"
        apt install -y --only-upgrade dante-server >/dev/null 2>&1 || true
    fi
fi

# --- Создание системных пользователей для SOCKS (PAM / username в Dante) ---
print_step "Создание системных пользователей SOCKS (${#SOCKS_ACCOUNT_NAMES[@]})"
CONFIG_FILE="./config/main.conf"

if [[ "$DRY_RUN" == "true" ]]; then
    print_warn "(DRY RUN) Создание пользователей: ${SOCKS_ACCOUNT_NAMES[*]}"
    log_info "[DRY RUN] Создание пользователей SOCKS"
else
    for ((i = 0; i < ${#SOCKS_ACCOUNT_NAMES[@]}; i++)); do
        _suser="${SOCKS_ACCOUNT_NAMES[$i]}"
        _spass="${SOCKS_ACCOUNT_PASSWORDS[$i]}"

        if id "$_suser" &>/dev/null; then
            print_info "Пользователь $_suser уже существует — обновление пароля"
            log_info "User $_suser already exists — updating password"
        else
            if useradd -r -s /usr/sbin/nologin "$_suser" >/dev/null 2>&1; then
                print_success "Пользователь $_suser создан"
                log_info "User $_suser created"
            else
                print_error "Ошибка создания пользователя $_suser"
                log_error "useradd $_suser failed"
                [[ "$FORCE_MODE" != "true" ]] && exit 1
            fi
        fi

        if echo "$_suser:$_spass" | chpasswd >/dev/null 2>&1; then
            print_success "Пароль для $_suser установлен"
            log_info "Password set for $_suser"
        else
            print_error "Ошибка установки пароля для $_suser"
            log_error "chpasswd failed for $_suser"
            [[ "$FORCE_MODE" != "true" ]] && exit 1
        fi
    done

    if [[ -f "$CONFIG_FILE" ]]; then
        if ! grep -q '^SOCKS_DEFAULT_USERS=' "$CONFIG_FILE" 2>/dev/null; then
            _saved="${SOCKS_USERS_LINE//\\/\\\\}"
            _saved="${_saved//\"/\\\"}"
            echo "SOCKS_DEFAULT_USERS=\"$_saved\"" >> "$CONFIG_FILE"
            print_success "SOCKS_DEFAULT_USERS добавлен в $CONFIG_FILE"
            log_info "SOCKS_DEFAULT_USERS appended to main.conf"
        fi
    else
        log_warn "Файл $CONFIG_FILE не найден — список SOCKS не записан"
    fi
fi

# --- Резервная копия конфигурации ---
if [[ -f /etc/danted.conf ]] && [[ "$DRY_RUN" != "true" ]]; then
    cp /etc/danted.conf /etc/danted.conf.bak.$(date +%Y%m%d_%H%M%S) 2>/dev/null
    log_info "Создана резервная копия danted.conf"
fi

# --- Создание конфигурации Dante ---
print_step "Создание конфигурации Dante"
if [[ "$DRY_RUN" == "true" ]]; then
    print_warn "(DRY RUN) Создание /etc/danted.conf"
    log_info "[DRY RUN] Создание конфигурации"
else
    cat > /etc/danted.conf <<EOF
# === Dante SOCKS5 Configuration ===
# Generated by server_script installer
# Domain: $DOMAIN
# Date: $(date)

# === Логирование ===
logoutput: /var/log/danted/access.log

# === Входящие подключения ===
internal: $NET_IFACE port = $SOCKS_PORT

# === Исходящий трафик ===
external: $NET_IFACE

# === Методы аутентификации ===
socksmethod: username
clientmethod: none

# === Пользователь от которого работает демон ===
user.privileged: root
user.unprivileged: nobody

# === Разрешить входящие подключения от всех ===
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect error
}

# === SOCKS5: разрешить аутентифицированным пользователям TCP ===
socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    protocol: tcp udp
    socksmethod: username
    log: connect disconnect error
}

# === Запретить всё остальное ===
socks block {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect error
}
EOF

    print_success "Конфигурация /etc/danted.conf создана"
    log_info "File /etc/danted.conf created"
fi

# --- Создание директории логов ---
print_step "Создание директории логов"
if [[ "$DRY_RUN" != "true" ]]; then
    mkdir -p /var/log/danted
    chown nobody:nogroup /var/log/danted 2>/dev/null || chown nobody:nobody /var/log/danted 2>/dev/null
    chmod 755 /var/log/danted
    print_success "Директория /var/log/danted создана"
    log_info "Log directory /var/log/danted created"
fi

# --- Проверка конфигурации ---
print_step "Проверка конфигурации Dante"
if [[ "$DRY_RUN" == "true" ]]; then
    print_warn "(DRY RUN) danted -V"
    log_info "[DRY RUN] Проверка конфигурации"
else
    if danted -V -f /etc/danted.conf >/dev/null 2>&1; then
        print_success "Конфигурация корректна"
        log_info "danted config check passed"
    else
        print_error "Ошибка в конфигурации Dante"
        log_error "danted -V -f /etc/danted.conf failed"
        danted -V -f /etc/danted.conf 2>&1 | tee -a "$LOG_FILE"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
fi

# --- Настройка UFW ---
if [[ "${ENABLE_UFW:-true}" == "true" ]]; then
    print_step "Настройка UFW firewall"
    if [[ "$DRY_RUN" == "true" ]]; then
        print_warn "(DRY RUN) ufw allow $SOCKS_PORT/tcp"
        log_info "[DRY RUN] Открытие порта $SOCKS_PORT"
    else
        if command -v ufw &>/dev/null; then
            log_info "Открытие порта $SOCKS_PORT в UFW"
            if ufw status | grep -q "Status: active"; then
                ufw allow "$SOCKS_PORT/tcp" comment "Dante SOCKS5 Proxy" >/dev/null 2>&1
                ufw reload >/dev/null 2>&1
            else
                ufw allow "$SOCKS_PORT/tcp" comment "Dante SOCKS5 Proxy" >/dev/null 2>&1
                echo "y" | ufw enable >/dev/null 2>&1
            fi
            print_success "Порт $SOCKS_PORT открыт"
            log_info "UFW: порт $SOCKS_PORT открыт"
        else
            print_warn "UFW не установлен, пропуск настройки firewall"
            log_warn "UFW not found, skipping firewall setup"
        fi
    fi
fi

# --- Запуск Dante ---
print_step "Запуск сервиса danted"
if [[ "$DRY_RUN" == "true" ]]; then
    print_warn "(DRY RUN) systemctl enable/restart danted"
    log_info "[DRY RUN] Запуск danted"
else
    systemctl enable danted >/dev/null 2>&1
    systemctl restart danted >/dev/null 2>&1
    sleep 3

    if systemctl is-active --quiet danted; then
        print_success "danted запущен"
        log_info "danted успешно запущен"
    else
        print_error "Ошибка запуска danted"
        log_error "systemctl start danted failed"
        journalctl -xeu danted --no-pager -n 20 | tee -a "$LOG_FILE"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
fi

# --- Проверка порта ---
print_step "Проверка работы SOCKS5 прокси"
if [[ "$DRY_RUN" == "true" ]]; then
    print_warn "(DRY RUN) Проверка порта $SOCKS_PORT"
    log_info "[DRY RUN] Проверка порта"
else
    sleep 2
    if ss -tuln 2>/dev/null | grep -q ":$SOCKS_PORT "; then
        print_success "SOCKS5 прокси слушает на порту $SOCKS_PORT"
        log_info "SOCKS5 прокси активен на порту $SOCKS_PORT"
    else
        print_error "SOCKS5 прокси не слушает на порту $SOCKS_PORT"
        log_error "SOCKS5 port $SOCKS_PORT not listening"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
fi

# --- Итоговая информация ---
print_step "Информация о SOCKS5-прокси"
print_info "Адрес:    $SOCKS_URL (или $SERVER_IP)"
print_info "Порт:     $SOCKS_PORT"
print_info "Протокол: SOCKS5"
print_info "Учётные записи (${#SOCKS_ACCOUNT_NAMES[@]}):"
for ((i = 0; i < ${#SOCKS_ACCOUNT_NAMES[@]}; i++)); do
    print_info "  • ${SOCKS_ACCOUNT_NAMES[$i]} (пароль: как в main.conf / SOCKS_PASSWORD)"
done
print_info ""
print_info "Пример строки подключения (первый пользователь):"
print_info "  $SERVER_IP:$SOCKS_PORT:$SOCKS_USER:SOCKS_PASSWORD"

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "SOCKS5-прокси настроен:"
log_info "  URL: $SOCKS_URL:$SOCKS_PORT"
log_info "  Учётные записи: ${SOCKS_ACCOUNT_NAMES[*]}"
for ((i = 0; i < ${#SOCKS_ACCOUNT_NAMES[@]}; i++)); do
    log_info "  SOCKS: ${SOCKS_ACCOUNT_NAMES[$i]} (пароль из SOCKS_DEFAULT_USERS или SOCKS_PASSWORD)"
done
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# --- Команды управления ---
print_info ""
print_info "Управление:"
print_info "  systemctl status danted"
print_info "  systemctl restart danted"
print_info "  tail -f /var/log/danted/access.log"
print_info ""
print_info "Добавить пользователя:"
print_info "  useradd -r -s /usr/sbin/nologin username"
print_info "  echo 'username:password' | chpasswd"
print_info "  systemctl reload danted"
print_info ""
print_info "Тест подключения (с сервера):"
print_info "  curl -v --socks5 $SOCKS_USER:SOCKS_PASSWORD@$SOCKS_URL:$SOCKS_PORT http://ifconfig.me"
print_info ""
print_info "Тест подключения (с клиента):"
print_info "  curl --socks5-hostname $SOCKS_USER:SOCKS_PASSWORD@$SERVER_IP:$SOCKS_PORT http://ifconfig.me"

print_success "✅ Модуль SOCKS5-прокси (Dante) завершён"
log_info "Модуль 17-proxy-socks-dante.sh завершён успешно"
