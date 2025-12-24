#!/bin/bash
# modules/12-mail-opendkim.sh - Установка и настройка OpenDKIM, SPF, DMARC
# Часть Mail Server Deployment Module System

# --- Загрузка вспомогательных утилит ---
[[ -z "${UTIL_PRINT_LOADED}" ]] && source ./utils/print.sh 2>/dev/null
[[ -z "${UTIL_LOGGING_LOADED}" ]] && source ./utils/logging.sh 2>/dev/null
[[ -z "${UTIL_FUNCTIONS_LOADED}" ]] && source ./utils/functions.sh 2>/dev/null

# --- Проверка прав root ---
ensure_root

# --- Загружаем конфиг, если нужно ---
load_config || {
    print_error "Не удалось загрузить конфигурацию. Убедитесь, что ./config/main.conf существует и содержит DOMAIN, SERVER_IP, ADMIN_EMAIL."
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
print_step "Проверка необходимых переменных: DOMAIN, SERVER_IP, ADMIN_EMAIL"
for var in DOMAIN SERVER_IP ADMIN_EMAIL; do
    if [[ -z "${!var}" ]]; then
        print_error "Переменная $var не задана"
        log_error "$var is not set"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
done

# --- Проверка ОС ---
ensure_debian || {
    print_error "Поддерживается только Debian 11+"
    log_error "Unsupported OS. Only Debian 11+ is supported."
    [[ "$FORCE_MODE" != "true" ]] && exit 1
}

# --- Проверка наличия Postfix ---
if ! systemctl is-active --quiet postfix; then
    print_error "Postfix не запущен. Установите и настройте модуль 11-mail-postfix.sh перед этим."
    log_error "Postfix is not active. Install 11-mail-postfix.sh first."
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# --- Установка OpenDKIM ---
print_step "Установка OpenDKIM"
if ! dpkg -l | grep -q "^ii.*opendkim"; then
    if apt install -y opendkim opendkim-tools > /dev/null 2>&1; then
        print_success "OpenDKIM установлен"
        log_info "OpenDKIM installed successfully"
    else
        print_error "Не удалось установить OpenDKIM"
        log_error "Failed to install OpenDKIM"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
else
    print_success "OpenDKIM уже установлен — обновление пакетов"
    log_info "OpenDKIM is already installed — updating packages"
    if apt install -y --only-upgrade opendkim opendkim-tools > /dev/null 2>&1; then
        print_success "Пакеты OpenDKIM обновлены"
        log_info "OpenDKIM packages upgraded"
    else
        print_warning "Не удалось обновить пакеты OpenDKIM — продолжаем"
        log_warn "Failed to upgrade OpenDKIM packages — continuing"
    fi
fi

# --- Создание директорий ---
print_step "Создание директорий для OpenDKIM"
safe_mkdir "/etc/opendkim" "opendkim:opendkim" "755"
safe_mkdir "/etc/opendkim/keys" "opendkim:opendkim" "750"
safe_mkdir "/etc/opendkim/keys/$DOMAIN" "opendkim:opendkim" "750"

# --- Генерация DKIM-ключа ---
print_step "Генерация DKIM-ключа для домена $DOMAIN"
DKIM_SELECTOR="mail"  # Стандартный селектор

if [[ ! -f "/etc/opendkim/keys/$DOMAIN/$DKIM_SELECTOR.private" ]]; then
    opendkim-genkey -b 2048 -d "$DOMAIN" -D "/etc/opendkim/keys/$DOMAIN" -s "$DKIM_SELECTOR" -v > /dev/null 2>&1
    if [[ $? -eq 0 ]]; then
        # Устанавливаем права
        chown opendkim:opendkim "/etc/opendkim/keys/$DOMAIN/$DKIM_SELECTOR.private"
        chmod 600 "/etc/opendkim/keys/$DOMAIN/$DKIM_SELECTOR.private"
        chown opendkim:opendkim "/etc/opendkim/keys/$DOMAIN/$DKIM_SELECTOR.txt"
        chmod 644 "/etc/opendkim/keys/$DOMAIN/$DKIM_SELECTOR.txt"
        
        print_success "DKIM-ключ сгенерирован"
        log_info "DKIM key generated for $DOMAIN with selector '$DKIM_SELECTOR'"
    else
        print_error "Не удалось сгенерировать DKIM-ключ"
        log_error "Failed to generate DKIM key"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
else
    print_info "DKIM-ключ уже существует — пропуск генерации"
    log_info "DKIM key already exists — skipping generation"
fi

# --- Настройка opendkim.conf ---
print_step "Настройка /etc/opendkim.conf"
cat > /etc/opendkim.conf <<EOF
# Основные настройки
Mode    sv
Syslog  yes
SyslogSuccess yes
LogWhy  yes
UserID  opendkim:opendkim
Socket  inet:8891@localhost
PidFile /var/run/opendkim/opendkim.pid
OversignHeaders From
Canonicalization relaxed/simple

# Пути к файлам
KeyTable      /etc/opendkim/key.table
SigningTable  /etc/opendkim/signing.table
ExternalIgnoreList /etc/opendkim/trusted.hosts
InternalHosts /etc/opendkim/trusted.hosts
EOF

if [[ $? -eq 0 ]]; then
    print_success "/etc/opendkim.conf настроен"
    log_info "/etc/opendkim.conf configured"
else
    print_error "Не удалось настроить /etc/opendkim.conf"
    log_error "Failed to configure /etc/opendkim.conf"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# --- Настройка key.table ---
print_step "Настройка /etc/opendkim/key.table"
cat > /etc/opendkim/key.table <<EOF
$DKIM_SELECTOR._domainkey.$DOMAIN $DOMAIN:$DKIM_SELECTOR:/etc/opendkim/keys/$DOMAIN/$DKIM_SELECTOR.private
EOF

if [[ $? -eq 0 ]]; then
    print_success "/etc/opendkim/key.table настроен"
    log_info "/etc/opendkim/key.table configured"
else
    print_error "Не удалось настроить /etc/opendkim/key.table"
    log_error "Failed to configure /etc/opendkim/key.table"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# --- Настройка signing.table ---
print_step "Настройка /etc/opendkim/signing.table"
cat > /etc/opendkim/signing.table <<EOF
*@$DOMAIN $DKIM_SELECTOR._domainkey.$DOMAIN
EOF

if [[ $? -eq 0 ]]; then
    print_success "/etc/opendkim/signing.table настроен"
    log_info "/etc/opendkim/signing.table configured"
else
    print_error "Не удалось настроить /etc/opendkim/signing.table"
    log_error "Failed to configure /etc/opendkim/signing.table"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# --- Настройка trusted.hosts ---
print_step "Настройка /etc/opendkim/trusted.hosts"
cat > /etc/opendkim/trusted.hosts <<EOF
127.0.0.1
localhost
$SERVER_IP
$DOMAIN
mail.$DOMAIN
EOF

if [[ $? -eq 0 ]]; then
    print_success "/etc/opendkim/trusted.hosts настроен"
    log_info "/etc/opendkim/trusted.hosts configured"
else
    print_error "Не удалось настроить /etc/opendkim/trusted.hosts"
    log_error "Failed to configure /etc/opendkim/trusted.hosts"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# --- Настройка интеграции с Postfix ---
print_step "Настройка интеграции OpenDKIM с Postfix"

POSTFIX_MAIN_CF="/etc/postfix/main.cf"

# Проверяем, есть ли уже настройки DKIM
if ! grep -q "^smtpd_milters" "$POSTFIX_MAIN_CF"; then
    # Добавляем настройки DKIM в конец файла
    cat >> "$POSTFIX_MAIN_CF" <<EOF

# === OpenDKIM Integration ===
smtpd_milters = inet:localhost:8891
non_smtpd_milters = \$smtpd_milters
milter_default_action = accept
milter_protocol = 6
EOF

    print_success "Интеграция OpenDKIM с Postfix настроена"
    log_info "OpenDKIM integration with Postfix configured"
else
    print_info "Интеграция OpenDKIM с Postfix уже настроена — пропуск"
    log_info "OpenDKIM integration with Postfix already configured — skipping"
fi

# --- Перезапуск служб ---
print_step "Перезапуск службы OpenDKIM"
systemctl enable opendkim > /dev/null 2>&1
if systemctl restart opendkim > /dev/null 2>&1; then
    print_success "Служба OpenDKIM перезапущена"
    log_info "OpenDKIM service restarted"
else
    print_error "Не удалось перезапустить OpenDKIM"
    log_error "Failed to restart OpenDKIM service"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

print_step "Перезапуск службы Postfix"
if systemctl restart postfix > /dev/null 2>&1; then
    print_success "Служба Postfix перезапущена"
    log_info "Postfix service restarted"
else
    print_error "Не удалось перезапустить Postfix"
    log_error "Failed to restart Postfix service"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# --- Проверка статуса служб ---
if systemctl is-active --quiet opendkim; then
    print_success "Служба OpenDKIM активна"
    log_info "OpenDKIM service is active"
else
    print_error "Служба OpenDKIM не запущена"
    log_error "OpenDKIM service is not active"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

if systemctl is-active --quiet postfix; then
    print_success "Служба Postfix активна"
    log_info "Postfix service is active"
else
    print_error "Служба Postfix не запущена"
    log_error "Postfix service is not active"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# --- Вывод DNS TXT-записи для DKIM ---
print_section "🔑 DKIM DNS ЗАПИСЬ ДЛЯ ДОБАВЛЕНИЯ"

if [[ -f "/etc/opendkim/keys/$DOMAIN/$DKIM_SELECTOR.txt" ]]; then
    DKIM_RECORD=$(grep -v '^;' "/etc/opendkim/keys/$DOMAIN/$DKIM_SELECTOR.txt" | tr -d '\n' | sed 's/  */ /g')
    # Форматируем для удобства
    PRINT_RECORD=$(echo "$DKIM_RECORD" | sed 's/" "/" + "/g')
    
    print_warning "СКОПИРУЙТЕ И ДОБАВЬТЕ ЭТУ TXT-ЗАПИСЬ В ВАШУ DNS-ЗОНУ:"
    print_color "BRIGHT_WHITE" "$PRINT_RECORD"
    log_info "DKIM DNS record: $DKIM_RECORD"
    
    print_info ""
    print_info "Имя записи: $DKIM_SELECTOR._domainkey.$DOMAIN"
    print_info "Тип: TXT"
    print_info "Значение: (см. выше)"
    print_info ""
    print_info "❗ После добавления записи подождите 5-10 минут и проверьте её:"
    print_info "   • dig +short txt $DKIM_SELECTOR._domainkey.$DOMAIN"
    print_info "   • https://dkimvalidator.com/"
else
    print_error "Файл DKIM-записи не найден: /etc/opendkim/keys/$DOMAIN/$DKIM_SELECTOR.txt"
    log_error "DKIM record file not found"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# --- Настройка SPF и DMARC ---
print_section "🛡️  НАСТРОЙКА SPF И DMARC"

# SPF Record
SPF_RECORD="v=spf1 mx a:$DOMAIN ip4:$SERVER_IP -all"
# DMARC Record
DMARC_RECORD="v=DMARC1; p=none; rua=mailto:$ADMIN_EMAIL; ruf=mailto:$ADMIN_EMAIL; fo=1; pct=100; adkim=s; aspf=s"

print_info "Генерация SPF и DMARC записей для домена $DOMAIN"

# --- Автоматическое добавление в зону BIND9 (если используется) ---
BIND_ZONE_FILE="/etc/bind/zones/db.$DOMAIN"
if [[ -f "$BIND_ZONE_FILE" ]] && grep -q "SOA" "$BIND_ZONE_FILE"; then
    print_step "Автоматическое добавление SPF и DMARC в зону BIND9"

    # Добавляем SPF запись (TXT для @)
    if ! grep -q "IN[[:space:]]*TXT.*v=spf1" "$BIND_ZONE_FILE"; then
        echo "@         IN      TXT     \"$SPF_RECORD\"" >> "$BIND_ZONE_FILE"
        print_success "SPF запись добавлена в зону"
        log_info "SPF record added to zone file"
    else
        print_info "SPF запись уже существует в зоне — пропуск"
        log_info "SPF record already exists in zone — skipping"
    fi

    # Добавляем DMARC запись (_dmarc.$DOMAIN)
    if ! grep -q "_dmarc.*IN[[:space:]]*TXT" "$BIND_ZONE_FILE"; then
        echo "_dmarc    IN      TXT     \"$DMARC_RECORD\"" >> "$BIND_ZONE_FILE"
        print_success "DMARC запись добавлена в зону"
        log_info "DMARC record added to zone file"
    else
        print_info "DMARC запись уже существует в зоне — пропуск"
        log_info "DMARC record already exists in zone — skipping"
    fi

    # Увеличиваем serial
    if command -v named-checkzone &> /dev/null; then
        # Создаём временную копию для генерации нового serial
        cp "$BIND_ZONE_FILE" "/tmp/db.$DOMAIN.tmp"
        # Генерируем новый serial (можно использовать функцию из 07-dns-server.sh, но для простоты сделаем здесь)
        NEW_SERIAL=$(date +%Y%m%d%H)
        sed -i "s/^\([[:space:]]*@.*IN[[:space:]]*SOA.*(\)[[:space:]]*[0-9]\{10\}/\1 $NEW_SERIAL/" "/tmp/db.$DOMAIN.tmp"
        if named-checkzone "$DOMAIN" "/tmp/db.$DOMAIN.tmp" > /dev/null 2>&1; then
            # Применяем новый serial
            sed -i "s/^\([[:space:]]*@.*IN[[:space:]]*SOA.*(\)[[:space:]]*[0-9]\{10\}/\1 $NEW_SERIAL/" "$BIND_ZONE_FILE"
            print_success "Serial зоны обновлён: $NEW_SERIAL"
            log_info "Zone serial updated to: $NEW_SERIAL"
        else
            print_warning "Не удалось обновить serial — зона может не обновиться"
            log_warn "Failed to update zone serial"
        fi
        rm -f "/tmp/db.$DOMAIN.tmp"
    fi

    # Перезагружаем зону
    if command -v rndc &> /dev/null; then
        if rndc reload "$DOMAIN" > /dev/null 2>&1; then
            print_success "Зона $DOMAIN перезагружена"
            log_info "Zone $DOMAIN reloaded"
        else
            systemctl reload named > /dev/null 2>&1 && print_info "Служба named перезагружена"
        fi
    fi
else
    print_warning "Файл зоны BIND9 не найден — пропуск автоматического добавления"
    log_warn "BIND9 zone file not found — skipping auto-add"
fi

# --- Вывод записей для ручного добавления ---
print_step "DNS TXT-записи для ручного добавления (если DNS не на этом сервере)"

print_color "BRIGHT_YELLOW" "SPF Запись:"
print_info "Имя: @ (или $DOMAIN)"
print_info "Тип: TXT"
print_color "WHITE" "Значение: $SPF_RECORD"
log_info "SPF record: $SPF_RECORD"

print_info ""
print_color "BRIGHT_YELLOW" "DMARC Запись:"
print_info "Имя: _dmarc.$DOMAIN"
print_info "Тип: TXT"
print_color "WHITE" "Значение: $DMARC_RECORD"
log_info "DMARC record: $DMARC_RECORD"

# --- Вывод ссылок для проверки DKIM, SPF, DMARC и DNS ---
print_section "🔍 ИНСТРУМЕНТЫ ДЛЯ ПРОВЕРКИ"

print_info "❗ После добавления всех записей (DKIM, SPF, DMARC) подождите 5-60 минут, затем проверьте:"
print_info ""

print_color "BRIGHT_YELLOW" "1. Проверка DKIM-записи:"
print_info "   • https://easydmarc.com/tools/dkim-lookup?domain=$DOMAIN&selector=mail"
log_info "DKIM check tool: https://easydmarc.com/tools/dkim-lookup?domain=$DOMAIN&selector=mail"

print_info ""
print_color "BRIGHT_YELLOW" "2. Проверка SPF-записи:"
print_info "   • https://www.kitterman.com/spf/validate.html"
print_info "   • https://vamsoft.com/support/tools/spf-policy-tester"
log_info "SPF check tool: https://www.kitterman.com/spf/validate.html"

print_info ""
print_color "BRIGHT_YELLOW" "3. Проверка DMARC-записи:"
print_info "   • https://dmarcly.com/tools/dmarc-record-checker"
print_info "   • https://mxtoolbox.com/dmarc.aspx"
log_info "DMARC check tool: https://dmarcly.com/tools/dmarc-record-checker"

print_info ""
print_color "BRIGHT_YELLOW" "4. Проверка DNS-распространения:"
print_info "   • Основной домен: https://iamroot.tech/dns-lookup/default.aspx?host=$DOMAIN"
print_info "   • DKIM-селектор:  https://iamroot.tech/dns-lookup/default.aspx?host=mail._domainkey.$DOMAIN"
print_info "   • DMARC:          https://iamroot.tech/dns-lookup/default.aspx?host=_dmarc.$DOMAIN"
log_info "DNS propagation check: https://iamroot.tech/dns-lookup/default.aspx?host=$DOMAIN"

print_info ""
print_color "BRIGHT_YELLOW" "5. Проверка портов сервера:"
print_info "   • Открыт ли порт 25? https://dnschecker.org/port-scanner.php"
log_info "Port check tool: https://dnschecker.org/port-scanner.php"

print_info ""
print_color "BRIGHT_YELLOW" "6. Тест доставляемости почты (Mail-Tester):"
print_info "   • Зайдите на https://mail-tester.com"
print_info "   • Скопируйте предоставленный email-адрес"
print_info "   • Отправьте тестовое письмо командой:"
print_info ""
print_color "WHITE" "     echo 'Тестовое письмо с DKIM/SPF/DMARC' | mail -s 'Email Auth Test' your-test-email@xxxx.mail-tester.com"
print_info ""
print_info "   • Вернитесь на сайт и нажмите 'Then check your score'"
log_info "Mail tester: https://mail-tester.com"

print_info ""
print_warning "💡 Совет: Для максимального балла (10/10) убедитесь, что все три записи (DKIM, SPF, DMARC) настроены правильно."

# --- Тестирование DKIM ---
print_step "Тестирование DKIM-подписи (генерация тестового письма)"

# Создаём тестовое письмо
TEST_EMAIL_FILE="/tmp/dkim-test.eml"
{
    echo "From: test@$DOMAIN"
    echo "To: $ADMIN_EMAIL"
    echo "Subject: DKIM Test Email"
    echo "Date: $(date -R)"
    echo "Message-ID: <$(date +%s).$(hostname)@$DOMAIN>"
    echo ""
    echo "This is a test email to verify DKIM signing."
} > "$TEST_EMAIL_FILE"

# Подписываем письмо
if opendkim-testmsg -d "$DOMAIN" -s "$DKIM_SELECTOR" -k "/etc/opendkim/keys/$DOMAIN/$DKIM_SELECTOR.private" < "$TEST_EMAIL_FILE" > /dev/null 2>&1; then
    print_success "DKIM-подпись тестового письма успешна"
    log_info "DKIM signature test passed"
else
    print_warning "DKIM-подпись тестового письма не удалась — возможно, проблема с конфигурацией"
    log_warn "DKIM signature test failed — check configuration"
fi

# Отправляем тестовое письмо
print_step "Отправка тестового письма с DKIM-подписью"
if sendmail -f "test@$DOMAIN" "$ADMIN_EMAIL" < "$TEST_EMAIL_FILE"; then
    print_success "Тестовое письмо отправлено на $ADMIN_EMAIL"
    log_info "DKIM test email sent to $ADMIN_EMAIL"
    print_info "Проверьте почтовый ящик (может попасть в спам). Используйте сервисы:"
    print_info "   • https://www.mail-tester.com/"
    print_info "   • https://dkimvalidator.com/"
else
    print_warning "Не удалось отправить тестовое письмо — возможно, проблема с Postfix"
    log_warn "Failed to send DKIM test email — check Postfix"
fi

# --- Очистка временного файла ---
rm -f "$TEST_EMAIL_FILE" > /dev/null 2>&1

# --- Информация для пользователя ---
print_section "📬 ИНФОРМАЦИЯ ОБ OPENDKIM"

print_success "✅ OpenDKIM успешно установлен и настроен"
print_info "Конфигурационные файлы:"
print_info "   • /etc/opendkim.conf"
print_info "   • /etc/opendkim/key.table"
print_info "   • /etc/opendkim/signing.table"
print_info "   • /etc/opendkim/trusted.hosts"
print_info ""
print_info "Ключи:"
print_info "   • Приватный: /etc/opendkim/keys/$DOMAIN/$DKIM_SELECTOR.private"
print_info "   • Публичный: /etc/opendkim/keys/$DOMAIN/$DKIM_SELECTOR.txt"
print_info ""
print_info "Команды:"
print_info "   • systemctl status opendkim"
print_info "   • systemctl restart opendkim"
print_info "   • opendkim-testkey -d $DOMAIN -s $DKIM_SELECTOR -vvv"
print_info ""
print_warning "❗ Не забудьте добавить TXT-записи DKIM, SPF и DMARC в вашу DNS-зону!"
print_warning "❗ Без этого письма будут помечаться как спам."

log_info "OpenDKIM setup completed. Waiting for DNS record propagation."
