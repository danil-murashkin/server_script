#!/bin/bash
# modules/13-mail-dovecot.sh - Установка и настройка Dovecot (IMAP/POP3)
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

# --- Проверка включения модуля ---
if [[ "${ENABLE_MAIL:-true}" != "true" ]]; then
    print_warning "Почтовый сервер отключен в конфигурации (ENABLE_MAIL=false)"
    log_info "Mail server installation skipped (ENABLE_MAIL=false)"
    exit 0
fi

# --- Проверка переменных ---
print_step "Проверка необходимых переменных"
for var in DOMAIN MAIL_DB_NAME MAIL_DB_USER MAIL_DB_PASSWORD; do
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

# --- Проверка наличия Postfix ---
if ! systemctl is-active --quiet postfix; then
    print_error "Postfix не запущен. Установите модуль 11-mail-postfix.sh"
    log_error "Postfix is not active"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# --- Установка Dovecot ---
print_step "Установка Dovecot"
DOVECOT_PACKAGES=(
    dovecot-core
    dovecot-imapd
    dovecot-pop3d
    dovecot-lmtpd
    dovecot-pgsql
    dovecot-sieve
    dovecot-managesieved
    ssl-cert
)

if ! dpkg -l | grep -q "^ii.*dovecot-core"; then
    if apt install -y "${DOVECOT_PACKAGES[@]}" > /dev/null 2>&1; then
        print_success "Dovecot установлен"
        log_info "Dovecot installed successfully"
    else
        print_error "Не удалось установить Dovecot"
        log_error "Failed to install Dovecot"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
else
    print_success "Dovecot уже установлен"
    log_info "Dovecot already installed"
fi

# --- Настройка dovecot-sql.conf.ext ---
print_step "Настройка dovecot-sql.conf.ext"

cat > /etc/dovecot/dovecot-sql.conf.ext <<EOF
driver = pgsql
connect = host=localhost dbname=$MAIL_DB_NAME user=$MAIL_DB_USER password=$MAIL_DB_PASSWORD

default_pass_scheme = SHA512-CRYPT

# Запрос для аутентификации (таблица mailbox из PostfixAdmin)
password_query = SELECT username as user, password FROM mailbox WHERE username='%u' AND active=true

# Запрос информации о пользователе (таблица mailbox из PostfixAdmin)
user_query = SELECT \
  CONCAT('/var/mail/vhosts/', maildir) as home, \
  CONCAT('maildir:/var/mail/vhosts/', maildir) as mail, \
  ${MAIL_SYSTEM_UID:-5000} AS uid, \
  ${MAIL_SYSTEM_GID:-5000} AS gid, \
  CONCAT('*:storage=', quota) AS quota_rule \
FROM mailbox \
WHERE username = '%u' AND active=true

# Итератор для всех пользователей
iterate_query = SELECT username FROM mailbox WHERE active=true
EOF

chown root:dovecot /etc/dovecot/dovecot-sql.conf.ext
chmod 640 /etc/dovecot/dovecot-sql.conf.ext

print_success "dovecot-sql.conf.ext настроен"
log_info "dovecot-sql.conf.ext configured"

# --- Настройка 10-auth.conf ---
print_step "Настройка аутентификации Dovecot"

# Включаем SQL аутентификацию
if ! grep -q "^!include auth-sql.conf.ext" /etc/dovecot/conf.d/10-auth.conf; then
    sed -i 's/#!include auth-sql.conf.ext/!include auth-sql.conf.ext/' /etc/dovecot/conf.d/10-auth.conf
    sed -i 's/^!include auth-system.conf.ext/#!include auth-system.conf.ext/' /etc/dovecot/conf.d/10-auth.conf
fi

# Отключаем plain-text аутентификацию без SSL
sed -i 's/#disable_plaintext_auth = yes/disable_plaintext_auth = yes/' /etc/dovecot/conf.d/10-auth.conf

print_success "Аутентификация настроена"
log_info "Dovecot authentication configured"

# --- Настройка 10-mail.conf ---
print_step "Настройка расположения почты"

cat > /etc/dovecot/conf.d/10-mail.conf <<EOF
mail_location = maildir:/var/mail/vhosts/%d/%n
mail_privileged_group = mail

# Пользователь и группа для почтовых ящиков
mail_uid = vmail
mail_gid = vmail

# Автоматическое создание папок
namespace inbox {
  inbox = yes
  
  mailbox Drafts {
    auto = subscribe
    special_use = \Drafts
  }
  mailbox Sent {
    auto = subscribe
    special_use = \Sent
  }
  mailbox Trash {
    auto = subscribe
    special_use = \Trash
  }
  mailbox Spam {
    auto = subscribe
    special_use = \Junk
  }
}

# Права доступа к файлам
mail_attachment_dir = /var/mail/vhosts/attachments
mail_attachment_min_size = 128k
mail_attachment_fs = sis posix
mail_attachment_hash = %{sha1}
EOF

print_success "Расположение почты настроено"
log_info "Mail location configured"

# --- Настройка 10-master.conf ---
print_step "Настройка служб Dovecot"

cat > /etc/dovecot/conf.d/10-master.conf <<EOF
service imap-login {
  inet_listener imap {
    port = 143
  }
  inet_listener imaps {
    port = 993
    ssl = yes
  }
}

service pop3-login {
  inet_listener pop3 {
    port = 110
  }
  inet_listener pop3s {
    port = 995
    ssl = yes
  }
}

service lmtp {
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0600
    user = postfix
    group = postfix
  }
}

service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0666
    user = postfix
    group = postfix
  }
  
  unix_listener auth-userdb {
    mode = 0600
    user = vmail
    group = vmail
  }
  
  user = dovecot
}

service auth-worker {
  user = vmail
}

service dict {
  unix_listener dict {
    mode = 0600
    user = vmail
    group = vmail
  }
}
EOF

print_success "Службы Dovecot настроены"
log_info "Dovecot services configured"

# --- Настройка 10-ssl.conf ---
print_step "Настройка SSL"

cat > /etc/dovecot/conf.d/10-ssl.conf <<EOF
ssl = required
ssl_cert = </etc/ssl/certs/ssl-cert-snakeoil.pem
ssl_key = </etc/ssl/private/ssl-cert-snakeoil.key

ssl_min_protocol = TLSv1.2
ssl_cipher_list = ALL:!LOW:!SSLv2:!EXP:!aNULL
ssl_prefer_server_ciphers = yes

ssl_dh = </usr/share/dovecot/dh.pem
EOF

print_success "SSL настроен"
log_info "SSL configured"

# --- Создание пользователя vmail ---
print_step "Проверка пользователя vmail"
if ! id vmail &>/dev/null; then
    groupadd -g ${MAIL_SYSTEM_GID:-5000} vmail >/dev/null 2>&1
    useradd -g vmail -u ${MAIL_SYSTEM_UID:-5000} vmail -d ${MAIL_VHOSTS_DIR:-/var/mail/vhosts} -m >/dev/null 2>&1
    print_success "Пользователь vmail создан"
    log_info "vmail user created"
else
    print_info "Пользователь vmail уже существует"
    log_info "vmail user already exists"
fi

# Создание директорий
mkdir -p ${MAIL_VHOSTS_DIR:-/var/mail/vhosts}/$DOMAIN
mkdir -p /var/mail/vhosts/attachments
chown -R vmail:vmail ${MAIL_VHOSTS_DIR:-/var/mail/vhosts}
chmod -R 770 ${MAIL_VHOSTS_DIR:-/var/mail/vhosts}

# --- Перезапуск Dovecot ---
print_step "Перезапуск службы Dovecot"
if systemctl restart dovecot > /dev/null 2>&1 && systemctl enable dovecot > /dev/null 2>&1; then
    print_success "Служба Dovecot перезапущена"
    log_info "Dovecot service restarted"
else
    print_error "Не удалось перезапустить Dovecot"
    log_error "Failed to restart Dovecot"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# --- Проверка статуса ---
if systemctl is-active --quiet dovecot; then
    print_success "Служба Dovecot активна"
    log_info "Dovecot service is active"
else
    print_error "Служба Dovecot не запущена"
    log_error "Dovecot service is not active"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# --- Перезапуск Postfix для применения LMTP ---
print_step "Перезапуск Postfix"
systemctl restart postfix > /dev/null 2>&1

# --- Настройка UFW ---
if [[ "${ENABLE_UFW:-true}" == "true" ]] && command -v ufw &> /dev/null; then
    print_step "Настройка UFW для IMAP/POP3"
    if ufw status | grep -q "Status: active"; then
        ufw allow 143/tcp > /dev/null 2>&1
        ufw allow 993/tcp > /dev/null 2>&1
        ufw allow 110/tcp > /dev/null 2>&1
        ufw allow 995/tcp > /dev/null 2>&1
        print_success "Правила UFW применены"
        log_info "UFW rules applied"
    fi
fi

# --- Информация ---
print_section "📬 DOVECOT УСТАНОВЛЕН"
print_success "✅ Dovecot успешно настроен"
print_info "База данных: $MAIL_DB_NAME"
print_info "Таблица: mailbox (PostfixAdmin)"
print_info "Протоколы: IMAP (143/993), POP3 (110/995)"
print_info "Почтовые ящики: ${MAIL_VHOSTS_DIR:-/var/mail/vhosts}"
print_info ""
print_info "Следующий шаг: установите модуль 14-webadmin-postfixadmin.sh"

log_info "Dovecot setup completed"