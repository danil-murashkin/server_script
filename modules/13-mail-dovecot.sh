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

if ! command -v dovecot &>/dev/null; then
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
print_step "Настройка SSL для Dovecot"

# Получаем пути к SSL сертификатам
SSL_CERT=$(get_ssl_cert_path "$DOMAIN")
SSL_KEY=$(get_ssl_key_path "$DOMAIN")

# Проверяем существование сертификатов
if [[ -f "$SSL_CERT" ]] && [[ -f "$SSL_KEY" ]]; then
    print_success "SSL сертификаты найдены"
    log_info "SSL certificates found: $SSL_CERT, $SSL_KEY"
    
    # Создаем конфигурацию с реальными сертификатами
    cat > /etc/dovecot/conf.d/10-ssl.conf <<EOF
# SSL включен
ssl = required

# Пути к SSL сертификатам
ssl_cert = <$SSL_CERT
ssl_key = <$SSL_KEY

# Современные безопасные протоколы (только TLSv1.2 и TLSv1.3)
ssl_min_protocol = TLSv1.2
ssl_prefer_server_ciphers = yes

# Безопасные cipher suites
ssl_cipher_list = HIGH:!aNULL:!MD5:!RC4:!DES:!3DES:!IDEA
ssl_cipher_suites = TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256

# Параметры Diffie-Hellman для forward secrecy
ssl_dh = </usr/share/dovecot/dh.pem

# Дополнительные настройки безопасности
ssl_options = no_compression
EOF

    print_success "SSL настроен с реальными сертификатами"
    log_info "SSL configured with real certificates"
    
    # Показываем информацию о типе сертификата
    case "$SSL_PROVIDER" in
        "letsencrypt")
            print_info "Используются Let's Encrypt сертификаты"
            log_info "Using Let's Encrypt certificates"
            ;;
        "self-signed")
            print_info "Используются самоподписанные сертификаты"
            print_warning "⚠️  Почтовые клиенты покажут предупреждение о безопасности"
            log_info "Using self-signed certificates"
            ;;
        "custom")
            print_info "Используются пользовательские сертификаты"
            log_info "Using custom certificates"
            ;;
    esac
else
    print_warning "SSL сертификаты не найдены - используется snakeoil"
    log_warn "SSL certificates not found - using snakeoil certificates"
    
    # Используем snakeoil как fallback
    cat > /etc/dovecot/conf.d/10-ssl.conf <<EOF
# SSL включен (с временными snakeoil сертификатами)
ssl = required

# Временные сертификаты (замените на реальные!)
ssl_cert = </etc/ssl/certs/ssl-cert-snakeoil.pem
ssl_key = </etc/ssl/private/ssl-cert-snakeoil.key

# Современные безопасные протоколы
ssl_min_protocol = TLSv1.2
ssl_prefer_server_ciphers = yes

# Безопасные cipher suites
ssl_cipher_list = HIGH:!aNULL:!MD5:!RC4:!DES:!3DES:!IDEA

# Параметры Diffie-Hellman
ssl_dh = </usr/share/dovecot/dh.pem
EOF
    
    print_warning "⚠️  ВНИМАНИЕ: Dovecot использует временные snakeoil сертификаты"
    print_info "Запустите модуль 04-certificates.sh для настройки SSL"
    log_warn "Dovecot using snakeoil certificates - setup proper SSL"
fi

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
log_info "Dovecot setup completed"

print_section "📌 КОНФИГУРАЦИЯ DOVECOT"
print_info "   • База данных:    $MAIL_DB_NAME"
print_info "   • Таблица:        mailbox (PostfixAdmin)"
print_info "   • Почтовые ящики: ${MAIL_VHOSTS_DIR:-/var/mail/vhosts}"
print_info "   • Пользователь:   vmail (${MAIL_SYSTEM_UID:-5000}:${MAIL_SYSTEM_GID:-5000})"

print_section "🔐 SSL/TLS НАСТРОЙКИ"
if [[ -f "$SSL_CERT" ]] && [[ -f "$SSL_KEY" ]]; then
    case "$SSL_PROVIDER" in
        "letsencrypt")
            print_success "✅ Let's Encrypt сертификаты активны"
            print_info "   • Сертификат:     $SSL_CERT"
            print_info "   • Приват. ключ:   $SSL_KEY"
            print_info "   • Автопродление:  Включено"
            ;;
        "self-signed")
            print_warning "⚠️  Самоподписанные сертификаты"
            print_info "   • Сертификат:     $SSL_CERT"
            print_info "   • Приват. ключ:   $SSL_KEY"
            print_warning "   Почтовые клиенты покажут предупреждение безопасности"
            ;;
        "custom")
            print_success "✅ Пользовательские сертификаты активны"
            print_info "   • Сертификат:     $SSL_CERT"
            print_info "   • Приват. ключ:   $SSL_KEY"
            ;;
    esac
else
    print_warning "⚠️  Используются временные snakeoil сертификаты"
    print_info "   • Сертификат:     /etc/ssl/certs/ssl-cert-snakeoil.pem"
    print_warning "   Настройте SSL через модуль 04-certificates.sh"
fi

print_section "🌐 ПРОТОКОЛЫ И ПОРТЫ"
print_info "   IMAP (чтение почты):"
print_info "   • Порт 143:  IMAP с STARTTLS (рекомендуется)"
print_info "   • Порт 993:  IMAPS (SSL с самого начала)"
print_info ""
print_info "   POP3 (скачивание почты):"
print_info "   • Порт 110:  POP3 с STARTTLS"
print_info "   • Порт 995:  POP3S (SSL с самого начала)"
print_info ""
print_info "   LMTP (доставка от Postfix):"
print_info "   • Сокет:     /var/run/dovecot/lmtp"

print_section "📋 НАСТРОЙКА ПОЧТОВОГО КЛИЕНТА"
print_info "Входящая почта (IMAP):"
print_info "   • Сервер:        mail.$DOMAIN"
print_info "   • Порт:          993 (IMAPS) или 143 (IMAP+STARTTLS)"
print_info "   • Безопасность:  SSL/TLS"
print_info "   • Имя:           полный email (user@$DOMAIN)"
print_info "   • Пароль:        пароль почтового ящика"
print_info ""
print_info "Исходящая почта (SMTP):"
print_info "   • Сервер:        mail.$DOMAIN"
print_info "   • Порт:          587 (рекомендуется)"
print_info "   • Безопасность:  STARTTLS"
print_info "   • Аутентификация: Требуется"

print_section "📋 ПОЛЕЗНЫЕ КОМАНДЫ"
print_color "DIM" "  Проверить статус:     systemctl status dovecot"
print_color "DIM" "  Посмотреть логи:      tail -f /var/log/mail.log"
print_color "DIM" "  Список подключений:   doveadm who"
print_color "DIM" "  Перезапустить:        systemctl restart dovecot"
print_color "DIM" "  Проверить конфиг:     doveconf -n"

print_section "🔍 ПРОВЕРКА ПОРТОВ"
print_color "DIM" "  IMAP:  ss -tlnp | grep :143"
print_color "DIM" "  IMAPS: ss -tlnp | grep :993"
print_color "DIM" "  POP3:  ss -tlnp | grep :110"
print_color "DIM" "  POP3S: ss -tlnp | grep :995"

print_section "🧪 ТЕСТИРОВАНИЕ"
print_color "DIM" "  Проверить SSL:        openssl s_client -connect mail.$DOMAIN:993"
print_color "DIM" "  Тест IMAP:            telnet mail.$DOMAIN 143"
print_color "DIM" "  Список ящиков:        doveadm mailbox list -u user@$DOMAIN"

print_info ""
print_section "➡️  СЛЕДУЮЩИЙ ШАГ"
print_info "Установите модуль 14-webadmin-postfixadmin.sh для веб-управления"

log_info "Dovecot setup completed with SSL certificates"
