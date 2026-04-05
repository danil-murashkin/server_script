#!/bin/bash
# modules/16-proxy-squid.sh - Установка и настройка прокси-сервера Squid
# Часть Server Deployment Module System
# Устанавливается ПЕРЕД OpenVPN для обеспечения туннелирования HTTP/HTTPS трафика

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
if [[ "${ENABLE_PROXY:-false}" != "true" ]]; then
    print_warning "Proxy Squid отключен в конфигурации (ENABLE_PROXY=false)"
    log_info "Proxy Squid installation skipped (ENABLE_PROXY=false)"
    exit 0
fi

# --- Проверка переменных ---
print_step "Проверка конфигурации прокси-сервера"

# Устанавливаем значения по умолчанию
PROXY_USER="${PROXY_USER:-proxyuser}"
PROXY_PASSWORD="${PROXY_PASSWORD:-$ADMIN_PASSWORD}"
HTTP_PROXY_PORT="${HTTP_PROXY_PORT:-3128}"
PROXY_SUBDOMAIN="${PROXY_SUBDOMAIN:-proxy}"
PROXY_URL="$PROXY_SUBDOMAIN.$DOMAIN"
PROXY_CACHE_SIZE="${PROXY_CACHE_SIZE:-100}"

# Список пользователей (как VPN_DEFAULT_CLIENTS): "user:pass,user2:pass2"; пустой pass → PROXY_PASSWORD
PROXY_USERS_LINE="${PROXY_DEFAULT_USERS:-${PROXY_USER}:}"

declare -a PROXY_ACCOUNT_NAMES=()
declare -a PROXY_ACCOUNT_PASSWORDS=()

IFS=',' read -ra _proxy_entries <<< "$PROXY_USERS_LINE"
for _raw in "${_proxy_entries[@]}"; do
    _entry="${_raw#"${_raw%%[![:space:]]*}"}"
    _entry="${_entry%"${_entry##*[![:space:]]}"}"
    [[ -z "$_entry" ]] && continue
    _name="${_entry%%:*}"
    _pass="${_entry#*:}"
    if [[ "$_name" == "$_entry" ]]; then
        _pass=""
    fi
    [[ -z "$_name" ]] && continue
    [[ -z "$_pass" ]] && _pass="$PROXY_PASSWORD"
    PROXY_ACCOUNT_NAMES+=("$_name")
    PROXY_ACCOUNT_PASSWORDS+=("$_pass")
done

if [[ ${#PROXY_ACCOUNT_NAMES[@]} -eq 0 ]]; then
    print_error "Не заданы пользователи прокси (PROXY_DEFAULT_USERS / PROXY_USER)"
    log_error "No proxy accounts configured"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# Первый логин — для обратной совместимости с PROXY_USER в выводе и старыми инструкциями
PROXY_USER="${PROXY_ACCOUNT_NAMES[0]}"

log_info "Прокси: $PROXY_URL:$HTTP_PROXY_PORT"
log_info "Пользователи (${#PROXY_ACCOUNT_NAMES[@]}): ${PROXY_ACCOUNT_NAMES[*]}"

# --- Проверка ОС ---
ensure_debian || {
    print_error "Поддерживается только Debian 11+"
    log_error "Unsupported OS"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
}

# --- Установка Squid ---
print_step "Установка Squid и утилит"
if [[ "$DRY_RUN" == "true" ]]; then
    print_warn "(DRY RUN) Установка: squid apache2-utils"
    log_info "[DRY RUN] Установка пакетов"
else
    log_info "Установка: squid apache2-utils"
    
    if ! dpkg -l | grep -q "^ii.*squid"; then
        if apt install -y squid apache2-utils >/dev/null 2>&1; then
            print_success "Squid установлен"
            log_info "Squid установлен успешно"
        else
            print_error "Ошибка установки Squid"
            log_error "apt install squid failed"
            [[ "$FORCE_MODE" != "true" ]] && exit 1
        fi
    else
        print_success "Squid уже установлен — обновление пакетов"
        log_info "Squid is already installed — updating packages"
        if apt install -y --only-upgrade squid apache2-utils >/dev/null 2>&1; then
            print_success "Пакеты Squid обновлены"
            log_info "Squid packages upgraded"
        else
            print_warn "Не удалось обновить пакеты Squid — продолжаем"
            log_warn "Failed to upgrade Squid packages — continuing"
        fi
    fi
fi

# --- Создание пользователей Squid (htpasswd) ---
print_step "Настройка аутентификации"
PASSWD_FILE="/etc/squid/passwd"
CONFIG_FILE="./config/main.conf"

if [[ "$DRY_RUN" == "true" ]]; then
    print_warn "(DRY RUN) Создание пользователей Squid: ${PROXY_ACCOUNT_NAMES[*]}"
    log_info "[DRY RUN] Создание пользователей прокси (${#PROXY_ACCOUNT_NAMES[@]})"
else
    log_info "Создание пользователей прокси (${#PROXY_ACCOUNT_NAMES[@]})"

    for ((i = 0; i < ${#PROXY_ACCOUNT_NAMES[@]}; i++)); do
        _puser="${PROXY_ACCOUNT_NAMES[$i]}"
        _ppass="${PROXY_ACCOUNT_PASSWORDS[$i]}"

        if [[ $i -eq 0 ]] && { [[ ! -f "$PASSWD_FILE" ]] || [[ ! -s "$PASSWD_FILE" ]]; }; then
            if ! htpasswd -b -c "$PASSWD_FILE" "$_puser" "$_ppass" >/dev/null 2>&1; then
                print_error "Ошибка создания файла паролей Squid (пользователь $_puser)"
                log_error "htpasswd -c failed for $_puser"
                [[ "$FORCE_MODE" != "true" ]] && exit 1
            fi
            print_success "Пользователь $_puser создан (новый файл $PASSWD_FILE)"
            log_info "Squid htpasswd: created $_puser"
        else
            if ! htpasswd -b "$PASSWD_FILE" "$_puser" "$_ppass" >/dev/null 2>&1; then
                print_error "Ошибка добавления/обновления пользователя $_puser"
                log_error "htpasswd -b failed for $_puser"
                [[ "$FORCE_MODE" != "true" ]] && exit 1
            fi
            print_success "Пользователь $_puser добавлен или обновлён"
            log_info "Squid htpasswd: updated $_puser"
        fi
    done

    chmod 640 "$PASSWD_FILE"
    chown root:proxy "$PASSWD_FILE" 2>/dev/null || chown root:squid "$PASSWD_FILE" 2>/dev/null

    # Сохраняем список учёток в main.conf (если ключа ещё нет), по аналогии с VPN_DEFAULT_CLIENTS
    if [[ -f "$CONFIG_FILE" ]]; then
        if ! grep -q '^PROXY_DEFAULT_USERS=' "$CONFIG_FILE" 2>/dev/null; then
            _saved="${PROXY_USERS_LINE//\\/\\\\}"
            _saved="${_saved//\"/\\\"}"
            echo "PROXY_DEFAULT_USERS=\"$_saved\"" >> "$CONFIG_FILE"
            print_success "PROXY_DEFAULT_USERS добавлен в $CONFIG_FILE"
            log_info "PROXY_DEFAULT_USERS appended to main.conf"
        fi
    else
        log_warn "Файл $CONFIG_FILE не найден — список пользователей прокси не записан"
    fi
fi

# --- Резервная копия конфигурации ---
if [[ -f /etc/squid/squid.conf ]] && [[ "$DRY_RUN" != "true" ]]; then
    cp /etc/squid/squid.conf /etc/squid/squid.conf.bak.$(date +%Y%m%d_%H%M%S) 2>/dev/null
    log_info "Создана резервная копия squid.conf"
fi

# --- Создание конфигурации ---
print_step "Создание конфигурации Squid"
if [[ "$DRY_RUN" == "true" ]]; then
    print_warn "(DRY RUN) Создание /etc/squid/squid.conf"
    log_info "[DRY RUN] Создание конфигурации"
else
    cat > /etc/squid/squid.conf <<EOF
# === Squid Proxy Configuration ===
# Generated by server_script installer
# Domain: $DOMAIN
# Date: $(date)

# === Порт прокси-сервера ===
http_port $HTTP_PROXY_PORT

# === Аутентификация ===
auth_param basic program /usr/lib/squid/basic_ncsa_auth $PASSWD_FILE
auth_param basic children 5
auth_param basic realm Squid Proxy Server - $DOMAIN
auth_param basic credentialsttl 2 hours

# === ACL (Access Control Lists) ===
acl authenticated proxy_auth REQUIRED
acl SSL_ports port 443
acl Safe_ports port 80          # http
acl Safe_ports port 21          # ftp
acl Safe_ports port 443         # https
acl Safe_ports port 70          # gopher
acl Safe_ports port 210         # wais
acl Safe_ports port 1025-65535  # unregistered ports
acl Safe_ports port 280         # http-mgmt
acl Safe_ports port 488         # gss-http
acl Safe_ports port 591         # filemaker
acl Safe_ports port 777         # multiling http
acl CONNECT method CONNECT

# === Правила доступа ===
# Разрешить только безопасные порты
http_access deny !Safe_ports

# Запретить CONNECT к небезопасным портам
http_access deny CONNECT !SSL_ports

# Разрешить localhost без аутентификации
http_access allow localhost

# Требовать аутентификацию для всех остальных
http_access allow authenticated

# Запретить всё остальное
http_access deny all

# === Кэширование ===
cache_dir ufs /var/spool/squid $PROXY_CACHE_SIZE 16 256
coredump_dir /var/spool/squid

# Паттерны обновления кэша
refresh_pattern ^ftp:           1440    20%     10080
refresh_pattern ^gopher:        1440    0%      1440
refresh_pattern -i (/cgi-bin/|\?) 0     0%      0
refresh_pattern .               0       20%     4320

# === Логирование ===
access_log daemon:/var/log/squid/access.log squid
cache_log /var/log/squid/cache.log
cache_store_log /var/log/squid/store.log

# === Безопасность ===
# Скрыть версию Squid
httpd_suppress_version_string on

# Отключить via header (анонимность)
via off

# Отключить forwarded_for (анонимность)
forwarded_for off

# === DNS и таймауты ===
dns_nameservers 8.8.8.8 1.1.1.1 8.8.4.4
dns_v4_first on

# Таймауты подключения
connect_timeout 60 seconds
read_timeout 300 seconds
request_timeout 60 seconds

# === Размеры ===
maximum_object_size 50 MB
maximum_object_size_in_memory 512 KB

# === Производительность ===
# Количество файловых дескрипторов
max_filedescriptors 4096

# === Дополнительные настройки ===
# Отключить ICP
icp_port 0

# Hostname
visible_hostname $PROXY_URL
unique_hostname $PROXY_URL
EOF

    print_success "Конфигурация создана"
    log_info "Файл /etc/squid/squid.conf создан"
fi

# --- Инициализация кэша ---
print_step "Инициализация кэша Squid"
if [[ "$DRY_RUN" == "true" ]]; then
    print_warn "(DRY RUN) squid -z"
    log_info "[DRY RUN] Инициализация кэша"
else
    # Останавливаем Squid если запущен
    systemctl stop squid >/dev/null 2>&1
    
    if squid -z >/dev/null 2>&1; then
        print_success "Кэш инициализирован"
        log_info "Кэш Squid инициализирован"
    else
        print_warn "Предупреждение при инициализации кэша (возможно уже инициализирован)"
        log_warn "squid -z returned non-zero (may be already initialized)"
    fi
fi

# --- Проверка конфигурации ---
print_step "Проверка конфигурации"
if [[ "$DRY_RUN" == "true" ]]; then
    print_warn "(DRY RUN) squid -k parse"
    log_info "[DRY RUN] Проверка конфигурации"
else
    if squid -k parse >/dev/null 2>&1; then
        print_success "Конфигурация корректна"
        log_info "Конфигурация Squid проверена"
    else
        print_error "Ошибка в конфигурации Squid"
        log_error "squid -k parse failed"
        squid -k parse 2>&1 | tee -a "$LOG_FILE"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
fi

# --- Настройка firewall (UFW) ---
if [[ "${ENABLE_UFW:-true}" == "true" ]]; then
    print_step "Настройка UFW firewall"
    if [[ "$DRY_RUN" == "true" ]]; then
        print_warn "(DRY RUN) ufw allow $HTTP_PROXY_PORT/tcp"
        log_info "[DRY RUN] Открытие порта $HTTP_PROXY_PORT"
    else
        if command -v ufw &> /dev/null; then
            log_info "Открытие порта $HTTP_PROXY_PORT в UFW"
            if ufw status | grep -q "Status: active"; then
                ufw allow "$HTTP_PROXY_PORT/tcp" comment "Squid Proxy" >/dev/null 2>&1
                ufw reload >/dev/null 2>&1
            else
                ufw allow "$HTTP_PROXY_PORT/tcp" comment "Squid Proxy" >/dev/null 2>&1
                echo "y" | ufw enable >/dev/null 2>&1
            fi
            print_success "Порт $HTTP_PROXY_PORT открыт"
            log_info "UFW: порт $HTTP_PROXY_PORT открыт"
        else
            print_warn "UFW не установлен, пропуск настройки firewall"
            log_warn "UFW not found, skipping firewall setup"
        fi
    fi
fi

# --- Запуск Squid ---
print_step "Запуск сервиса Squid"
if [[ "$DRY_RUN" == "true" ]]; then
    print_warn "(DRY RUN) systemctl enable/restart squid"
    log_info "[DRY RUN] Запуск Squid"
else
    log_info "Включение и запуск Squid"
    systemctl enable squid >/dev/null 2>&1
    systemctl restart squid >/dev/null 2>&1
    sleep 3
    
    if systemctl is-active --quiet squid; then
        print_success "Squid запущен"
        log_info "Squid успешно запущен"
    else
        print_error "Ошибка запуска Squid"
        log_error "systemctl start squid failed"
        journalctl -xeu squid --no-pager -n 20 | tee -a "$LOG_FILE"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
fi

# --- Проверка порта ---
print_step "Проверка работы прокси"
if [[ "$DRY_RUN" == "true" ]]; then
    print_warn "(DRY RUN) Проверка порта $HTTP_PROXY_PORT"
    log_info "[DRY RUN] Проверка порта"
else
    sleep 2
    if ss -tuln 2>/dev/null | grep -q ":$HTTP_PROXY_PORT " || netstat -tuln 2>/dev/null | grep -q ":$HTTP_PROXY_PORT "; then
        print_success "Прокси слушает на порту $HTTP_PROXY_PORT"
        log_info "Прокси активен на порту $HTTP_PROXY_PORT"
    else
        print_error "Прокси не слушает на порту $HTTP_PROXY_PORT"
        log_error "Proxy port $HTTP_PROXY_PORT not listening"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
fi

# --- Итоговая информация ---
print_step "Информация о прокси-сервере"
print_info "Адрес:   $PROXY_URL (или $SERVER_IP)"
print_info "Порт:    $HTTP_PROXY_PORT"
print_info "Учётные записи (${#PROXY_ACCOUNT_NAMES[@]}):"
for ((i = 0; i < ${#PROXY_ACCOUNT_NAMES[@]}; i++)); do
    print_info "  • ${PROXY_ACCOUNT_NAMES[$i]} (пароль: как в main.conf / PROXY_PASSWORD)"
done
print_info ""
print_info "Пример строки подключения (первый пользователь):"
print_info "  $SERVER_IP:$HTTP_PROXY_PORT:$PROXY_USER:PROXY_PASSWORD"

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Прокси-сервер настроен:"
log_info "  URL: $PROXY_URL:$HTTP_PROXY_PORT"
log_info "  Учётные записи: ${PROXY_ACCOUNT_NAMES[*]}"
for ((i = 0; i < ${#PROXY_ACCOUNT_NAMES[@]}; i++)); do
    log_info "  Учётная запись: ${PROXY_ACCOUNT_NAMES[$i]} (порт $HTTP_PROXY_PORT; пароль из PROXY_DEFAULT_USERS или PROXY_PASSWORD)"
done
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# --- Команды управления ---
print_info ""
print_info "Управление:"
print_info "  systemctl status squid"
print_info "  systemctl restart squid"
print_info "  tail -f /var/log/squid/access.log"
print_info ""
print_info "Добавить пользователя:"
print_info "  htpasswd -b /etc/squid/passwd username password"
print_info "  systemctl reload squid"
print_info ""
print_info "Тест подключения:"
print_info "  curl -x http://$PROXY_USER:PROXY_PASSWORD@$PROXY_URL:$HTTP_PROXY_PORT http://ifconfig.me"
print_info ""
print_info "Расширение для браузера (Chrome/Edge):"
print_info "  https://chromewebstore.google.com/detail/lcbpobjekkgofogdbjjhgefgmmncfada"

print_success "✅ Модуль прокси-сервера завершён"
log_info "Модуль 16-proxy-squid.sh завершён успешно"
