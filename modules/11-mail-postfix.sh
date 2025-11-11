#!/bin/bash
# modules/11-mail-postfix.sh - Установка и настройка Postfix
# Часть Mail Server Deployment Module System

# --- Загрузка вспомогательных утилит ---
[[ -z "${UTIL_PRINT_LOADED}" ]] && source ./utils/print.sh 2>/dev/null
[[ -z "${UTIL_LOGGING_LOADED}" ]] && source ./utils/logging.sh 2>/dev/null
[[ -z "${UTIL_FUNCTIONS_LOADED}" ]] && source ./utils/functions.sh 2>/dev/null

# --- Проверка прав root ---
ensure_root

# --- Загружаем конфиг ---
load_config || {
    print_error "Не удалось загрузить конфигурацию"
    log_error "Failed to load required configuration"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
}

# --- Проверка переменных ---
print_step "Проверка необходимых переменных"
for var in DOMAIN ADMIN_EMAIL ADMIN_PASSWORD MAIL_DB_NAME MAIL_DB_USER MAIL_DB_PASSWORD; do
    if [[ -z "${!var}" ]]; then
        print_error "Переменная $var не задана"
        log_error "$var is not set"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
done

# --- Проверка ОС ---
ensure_debian || {
    print_error "Поддерживается только Debian 11+"
    log_error "Unsupported OS"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
}

# --- Установка Postfix ---
print_step "Установка Postfix"
POSTFIX_PACKAGES=(
    postfix
    postfix-pgsql
    mailutils
)

if ! dpkg -l | grep -q "^ii.*postfix"; then
    export DEBIAN_FRONTEND=noninteractive
    debconf-set-selections <<< "postfix postfix/mailname string $DOMAIN"
    debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Internet Site'"
    
    if apt install -y "${POSTFIX_PACKAGES[@]}" > /dev/null 2>&1; then
        print_success "Postfix установлен"
        log_info "Postfix installed successfully"
    else
        print_error "Не удалось установить Postfix"
        log_error "Failed to install Postfix"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
else
    print_success "Postfix уже установлен"
    log_info "Postfix already installed"
fi

# --- Настройка /etc/mailname ---
print_step "Настройка /etc/mailname"
echo "$DOMAIN" > /etc/mailname
log_info "/etc/mailname configured"

# --- Основная настройка Postfix ---
print_step "Настройка основной конфигурации Postfix"
POSTFIX_MAIN_CF="/etc/postfix/main.cf"
cp "$POSTFIX_MAIN_CF" "$POSTFIX_MAIN_CF.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null

cat > "$POSTFIX_MAIN_CF" <<EOF
# Основные настройки
smtpd_banner = \$myhostname ESMTP \$mail_name (Debian/GNU)
biff = no
append_dot_mydomain = no
readme_directory = no

# TLS параметры
smtpd_tls_cert_file=/etc/ssl/certs/ssl-cert-snakeoil.pem
smtpd_tls_key_file=/etc/ssl/private/ssl-cert-snakeoil.key
smtpd_tls_security_level=may
smtp_tls_security_level=may
smtpd_tls_session_cache_database = btree:\${data_directory}/smtpd_scache
smtp_tls_session_cache_database = btree:\${data_directory}/smtp_scache

# Аутентификация SASL
smtpd_sasl_type = dovecot
smtpd_sasl_path = private/auth
smtpd_sasl_auth_enable = yes
smtpd_sasl_security_options = noanonymous
smtpd_sasl_local_domain = \$myhostname

# Основные параметры
myhostname = mail.$DOMAIN
mydomain = $DOMAIN
myorigin = /etc/mailname
mydestination = localhost, localhost.localdomain, \$myhostname
relayhost =
mynetworks = 127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128
mailbox_size_limit = 0
recipient_delimiter = +
inet_interfaces = all
inet_protocols = ipv4

# Виртуальные домены и пользователи (PostfixAdmin schema)
virtual_mailbox_domains = pgsql:/etc/postfix/pgsql-virtual-mailbox-domains.cf
virtual_mailbox_maps = pgsql:/etc/postfix/pgsql-virtual-mailbox-maps.cf
virtual_alias_maps = pgsql:/etc/postfix/pgsql-virtual-alias-maps.cf

# Параметры доставки
virtual_transport = lmtp:unix:private/dovecot-lmtp
local_transport = local
local_recipient_maps =

# Ограничения
smtpd_recipient_restrictions =
    permit_mynetworks,
    permit_sasl_authenticated,
    reject_unauth_destination,
    reject_rbl_client zen.spamhaus.org,
    reject_rbl_client bl.spamcop.net
EOF

log_info "Postfix main.cf configured"

# --- Создание конфигурационных файлов для PostgreSQL ---
print_step "Создание конфигурационных файлов PostgreSQL"
POSTFIX_PGSQL_DIR="/etc/postfix"

# Файл для виртуальных доменов (таблица domain из PostfixAdmin)
cat > "$POSTFIX_PGSQL_DIR/pgsql-virtual-mailbox-domains.cf" <<EOF
user = $MAIL_DB_USER
password = $MAIL_DB_PASSWORD
hosts = localhost
dbname = $MAIL_DB_NAME
query = SELECT domain FROM domain WHERE domain='%s' AND active=true
EOF

# Файл для виртуальных почтовых ящиков (таблица mailbox из PostfixAdmin)
cat > "$POSTFIX_PGSQL_DIR/pgsql-virtual-mailbox-maps.cf" <<EOF
user = $MAIL_DB_USER
password = $MAIL_DB_PASSWORD
hosts = localhost
dbname = $MAIL_DB_NAME
query = SELECT maildir FROM mailbox WHERE username='%s' AND active=true
EOF

# Файл для алиасов (таблица alias из PostfixAdmin)
cat > "$POSTFIX_PGSQL_DIR/pgsql-virtual-alias-maps.cf" <<EOF
user = $MAIL_DB_USER
password = $MAIL_DB_PASSWORD
hosts = localhost
dbname = $MAIL_DB_NAME
query = SELECT goto FROM alias WHERE address='%s' AND active=true
EOF

# Устанавливаем права
chown root:postfix "$POSTFIX_PGSQL_DIR/pgsql-virtual-"*.cf
chmod 640 "$POSTFIX_PGSQL_DIR/pgsql-virtual-"*.cf

print_success "Конфигурационные файлы PostgreSQL созданы"
log_info "PostgreSQL configuration files created"

# --- Создание пользователя vmail ---
print_step "Создание системного пользователя vmail"
if ! id vmail &>/dev/null; then
    groupadd -g ${MAIL_SYSTEM_GID:-5000} vmail >/dev/null 2>&1
    useradd -g vmail -u ${MAIL_SYSTEM_UID:-5000} vmail -d ${MAIL_VHOSTS_DIR:-/var/mail/vhosts} -m >/dev/null 2>&1
    print_success "Пользователь vmail создан"
    log_info "vmail user created"
else
    print_info "Пользователь vmail уже существует"
    log_info "vmail user already exists"
fi

# Создание директории для почтовых ящиков
mkdir -p ${MAIL_VHOSTS_DIR:-/var/mail/vhosts}/$DOMAIN
chown -R vmail:vmail ${MAIL_VHOSTS_DIR:-/var/mail/vhosts}
chmod -R 770 ${MAIL_VHOSTS_DIR:-/var/mail/vhosts}

# --- Настройка master.cf для submission (порт 587) ---
print_step "Настройка submission (порт 587) в master.cf"
MASTER_CF="/etc/postfix/master.cf"

# Проверяем, есть ли уже настройка submission
if ! grep -q "^submission inet" "$MASTER_CF"; then
    cat >> "$MASTER_CF" <<'EOF'

# Submission port 587 для аутентифицированной отправки
submission inet n       -       y       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=may
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_sasl_type=dovecot
  -o smtpd_sasl_path=private/auth
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject_unauth_destination
EOF
    print_success "Настройка submission (порт 587) добавлена"
    log_info "Submission port 587 configured in master.cf"
else
    print_info "Настройка submission уже существует"
    log_info "Submission port already configured"
fi

# --- Перезапуск Postfix ---
print_step "Перезапуск службы Postfix"
if systemctl restart postfix > /dev/null 2>&1 && systemctl enable postfix > /dev/null 2>&1; then
    print_success "Служба Postfix перезапущена"
    log_info "Postfix service restarted"
else
    print_error "Не удалось перезапустить Postfix"
    log_error "Failed to restart Postfix"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# --- Проверка порта 587 ---
print_step "Проверка порта 587"
sleep 2
if ss -tlnp | grep -q ":587"; then
    print_success "Порт 587 (submission) слушается"
    log_info "Port 587 is listening"
else
    print_warning "Порт 587 не слушается - проверьте конфигурацию"
    log_warn "Port 587 is not listening"
fi

# --- Проверка статуса ---
if systemctl is-active --quiet postfix; then
    print_success "Служба Postfix активна"
    log_info "Postfix service is active"
else
    print_error "Служба Postfix не запущена"
    log_error "Postfix service is not active"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# --- Настройка UFW ---
if [[ "${ENABLE_UFW:-true}" == "true" ]] && command -v ufw &> /dev/null; then
    print_step "Настройка UFW для SMTP"
    if ufw status | grep -q "Status: active"; then
        ufw allow 25/tcp > /dev/null 2>&1
        ufw allow 587/tcp > /dev/null 2>&1
        ufw allow 465/tcp > /dev/null 2>&1
        print_success "Правила UFW применены"
        log_info "UFW rules applied"
    fi
fi

# --- Информация ---
print_section "📧 POSTFIX УСТАНОВЛЕН"
print_success "✅ Postfix успешно настроен"
print_info "База данных: $MAIL_DB_NAME"
print_info "Таблицы: domain, mailbox, alias (PostfixAdmin)"
print_info "Почтовые ящики: ${MAIL_VHOSTS_DIR:-/var/mail/vhosts}"
print_info ""
print_info "Следующий шаг: установите модуль 13-mail-dovecot.sh"

log_info "Postfix setup completed"
