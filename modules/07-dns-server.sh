#!/bin/bash
# modules/07-dns-server.sh - Установка и настройка BIND9 DNS сервера
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

# --- Проверка переменных ---
print_step "Проверка необходимых переменных: DOMAIN, SERVER_IP"
for var in DOMAIN SERVER_IP; do
    if [[ -z "${!var}" ]]; then
        print_error "Переменная $var не задана"
        log_error "$var is not set"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
done

# --- Генерация DNS_SERIAL с поддержкой инкремента ---
generate_serial() {
    local today=$(date +%Y%m%d)
    local current_serial=0
    local zone_file="/etc/bind/zones/db.$DOMAIN"
    
    # Если файл существует — читаем текущий serial
    if [[ -f "$zone_file" ]]; then
        current_serial=$(grep -E "^[[:space:]]*@.*IN[[:space:]]+SOA" -A1 "$zone_file" 2>/dev/null | \
                         grep -oE "[0-9]{10}" | head -1)
    fi
    
    # Извлекаем дату из текущего serial (первые 8 цифр)
    local current_date=${current_serial:0:8}
    
    # Если сегодняшняя дата совпадает — увеличиваем счётчик
    if [[ "$current_date" == "$today" ]]; then
        local counter=${current_serial:8:2}
        counter=$((10#$counter + 1))  # Преобразуем в число (игнорируя ведущие нули)
        # Ограничим счётчик до 99
        [[ $counter -gt 99 ]] && counter=99
        DNS_SERIAL="${today}$(printf "%02d" $counter)"
    else
        # Новая дата — начинаем с 00
        DNS_SERIAL="${today}00"
    fi
    
    print_info "Генерация DNS_SERIAL: $DNS_SERIAL"
    log_info "Generated DNS_SERIAL: $DNS_SERIAL"
}

generate_serial

# --- Установка пакетов ---
print_step "Установка BIND9 и dnsutils"
if ! command -v named &> /dev/null; then
    apt update -qq >/dev/null 2>&1
    if apt install -y bind9 dnsutils bind9utils bind9-doc > /dev/null 2>&1; then
        print_success "BIND9 и dnsutils установлены"
        log_info "BIND9 and dnsutils installed"
    else
        print_error "Не удалось установить BIND9"
        log_error "Failed to install BIND9"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
else
    print_success "BIND9 уже установлен"
    log_info "BIND9 is already installed"
fi

# --- Генерация rndc.key ---
print_step "Генерация rndc.key"
if [[ ! -f /etc/bind/rndc.key ]]; then
    if rndc-confgen -a -c /etc/bind/rndc.key > /dev/null 2>&1; then
        chown bind:bind /etc/bind/rndc.key
        chmod 640 /etc/bind/rndc.key
        print_success "rndc.key создан"
        log_info "rndc.key generated"
    else
        print_error "Не удалось сгенерировать rndc.key"
        log_error "Failed to generate rndc.key"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
else
    print_info "rndc.key уже существует — пропуск"
    log_info "rndc.key already exists — skipping"
fi

# --- Настройка named.conf.options ---
print_step "Настройка /etc/bind/named.conf.options"
cat > /etc/bind/named.conf.options <<EOF
options {
    directory "/var/cache/bind";
    version "DNS server";
    listen-on { ${SERVER_IP}; };
    allow-query { any; };
    allow-recursion { none; };
    allow-transfer { none; };
    dnssec-validation auto;
};
EOF

if [[ $? -eq 0 ]]; then
    print_success "named.conf.options настроен"
    log_info "named.conf.options configured"
else
    print_error "Не удалось записать named.conf.options"
    log_error "Failed to write named.conf.options"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# --- Настройка named.conf.local ---
print_step "Настройка /etc/bind/named.conf.local"
cat > /etc/bind/named.conf.local <<EOF
zone "${DOMAIN}" IN {
    type master;
    file "/etc/bind/zones/db.${DOMAIN}";
    allow-update { ${SERVER_IP}; };
    allow-transfer { ${SERVER_IP}; };
    notify yes;
};
EOF

if [[ $? -eq 0 ]]; then
    print_success "named.conf.local настроен"
    log_info "named.conf.local configured"
else
    print_error "Не удалось записать named.conf.local"
    log_error "Failed to write named.conf.local"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# --- Создание директории зон ---
print_step "Создание директории /etc/bind/zones"
safe_mkdir "/etc/bind/zones" "bind:bind" "755" || {
    print_error "Не удалось создать директорию зон"
    log_error "Failed to create zones directory"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
}

# --- Создание зонного файла с поддоменом git ---
print_step "Создание зонного файла: /etc/bind/zones/db.$DOMAIN"
cat > /etc/bind/zones/db.$DOMAIN <<EOF
\$TTL 1d
\$ORIGIN ${DOMAIN}.
@         IN      SOA   ns1.${DOMAIN}. hostmaster.${DOMAIN}. (
                                ${DNS_SERIAL} ; serial number                                   
                                12h        ; refresh
                                15m        ; update retry
                                3w         ; expiry
                                2h )       ; minimum
@         IN      NS      ns1.${DOMAIN}.
@         IN      NS      ns2.${DOMAIN}.
@         IN      MX  10  mail.${DOMAIN}.
@         IN      A       ${SERVER_IP}
ns1       IN      A       ${SERVER_IP}
ns2       IN      A       ${SERVER_IP}
www       IN      A       ${SERVER_IP}
git       IN      A       ${SERVER_IP}
mail      IN      A       ${SERVER_IP}
mailadmin IN      A       ${SERVER_IP}
webmail   IN      A       ${SERVER_IP}
cloud     IN      A       ${SERVER_IP}
vpn       IN      A       ${SERVER_IP}
proxy     IN      A       ${SERVER_IP}
test      IN      A       ${SERVER_IP}
EOF

if [[ $? -eq 0 ]]; then
    print_success "Зонный файл создан"
    log_info "Zone file created: /etc/bind/zones/db.$DOMAIN"
else
    print_error "Не удалось создать зонный файл"
    log_error "Failed to create zone file"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# --- Установка прав на зонные файлы ---
print_step "Установка владельца bind:bind для /etc/bind/zones"
chown -R bind:bind /etc/bind/zones && \
    print_success "Права установлены" && \
    log_info "Ownership set to bind:bind"

# --- Проверка конфигурации BIND ---
print_step "Проверка конфигурации BIND: named-checkconf"
if named-checkconf > /dev/null 2>&1; then
    print_success "Конфигурация BIND корректна"
    log_info "named-checkconf passed"
else
    print_error "Ошибки в конфигурации BIND"
    log_error "named-checkconf failed"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# --- Проверка зоны ---
print_step "Проверка зоны: named-checkzone $DOMAIN /etc/bind/zones/db.$DOMAIN"
if named-checkzone "$DOMAIN" "/etc/bind/zones/db.$DOMAIN" > /dev/null 2>&1; then
    print_success "Зона $DOMAIN корректна"
    log_info "named-checkzone passed for $DOMAIN"
else
    print_error "Ошибки в зоне $DOMAIN"
    log_error "named-checkzone failed for $DOMAIN"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# --- Управление службой BIND ---
print_step "Включение и запуск службы named"
systemctl enable named > /dev/null 2>&1 && \
systemctl restart named > /dev/null 2>&1 && \
    print_success "Служба named перезапущена" && \
    log_info "named service restarted"

# --- Проверка статуса службы ---
if systemctl is-active --quiet named; then
    print_success "Служба named активна"
    log_info "named service is active"
else
    print_error "Служба named не запущена"
    log_error "named service is not active"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# --- Разрешение DNS в UFW ---
print_step "Разрешение DNS в UFW"
if command -v ufw &> /dev/null; then
    if ufw status | grep -q "Bind9"; then
        print_info "Правило UFW для Bind9 уже существует"
        log_info "UFW rule for Bind9 already exists"
    else
        ufw allow 'Bind9' > /dev/null 2>&1 && \
            print_success "DNS разрешён в UFW" && \
            log_info "UFW: allowed Bind9"
    fi
else
    print_warning "UFW не установлен — пропуск настройки фаервола"
    log_warn "UFW not installed — skipping firewall config"
fi

# --- Перезагрузка зоны через rndc ---
print_step "Перезагрузка зоны $DOMAIN через rndc"
if command -v rndc &> /dev/null; then
    if rndc reload "$DOMAIN" > /dev/null 2>&1; then
        print_success "Зона $DOMAIN перезагружена через rndc"
        log_info "Zone $DOMAIN reloaded via rndc"
    else
        print_warning "Не удалось перезагрузить зону через rndc — пробуем systemctl reload"
        log_warn "rndc reload failed — falling back to systemctl"
        systemctl reload named > /dev/null 2>&1 && \
            print_success "Служба named перезагружена" && \
            log_info "named service reloaded via systemctl"
    fi
else
    print_warning "rndc не найден — перезагружаем службу"
    log_warn "rndc not found — reloading named service"
    systemctl reload named > /dev/null 2>&1 && \
        print_success "Служба named перезагружена" && \
        log_info "named service reloaded"
fi

# --- Тестирование DNS ---
print_step "Тестирование DNS: dig git.$DOMAIN"
dig_result=$(dig +short "git.$DOMAIN" 2>/dev/null)
if [[ -n "$dig_result" ]]; then
    print_success "Запись git.$DOMAIN разрешается: $dig_result"
    log_info "DNS record git.$DOMAIN resolves to: $dig_result"
else
    print_warning "Запись git.$DOMAIN пока не разрешается — возможно, зона ещё не загружена"
    log_warn "DNS record git.$DOMAIN does not resolve yet"
fi

# --- Вывод ключа rndc для удалённого управления ---
print_section "🔑 КЛЮЧ УПРАВЛЕНИЯ DNS (rndc)"

if [[ -f /etc/bind/rndc.key ]]; then
    print_info "rndc.key успешно создан. Содержимое ключа:"
    log_info "rndc.key content:"
    
    # Читаем ключ и выводим в удобном формате
    KEY_SECRET=$(grep "secret" /etc/bind/rndc.key | awk '{print $2}' | tr -d '";')
    KEY_ALGORITHM=$(grep "algorithm" /etc/bind/rndc.key | awk '{print $2}' | tr -d '";')
    
    print_warning "Скопируйте эти данные для настройки удалённого управления DNS (если нужно):"
    print_info "Алгоритм: $KEY_ALGORITHM"
    print_info "Секретный ключ: $KEY_SECRET"
    
    log_info "rndc algorithm: $KEY_ALGORITHM"
    log_info "rndc secret: $KEY_SECRET"
    
    # Выводим компактную информацию для rndc
    print_color "DIM" "rndc config: key=rndc-key algorithm=$KEY_ALGORITHM secret=$KEY_SECRET server=$SERVER_IP port=953"
else
    print_error "rndc.key не найден — управление зоной будет ограничено"
    log_error "rndc.key not found — zone management will be limited"
fi

# --- Вывод всех DNS-записей для копирования ---
print_section "📋 ЗАПИСИ ДЛЯ НАСТРОЙКИ ДОМЕНА"

print_info "Скопируйте и добавьте эти записи в панель управления вашим доменом ($DOMAIN):"
print_separator "=" 80

# Выводим NS-записи (главное — их нужно прописать у регистратора)
print_color "BRIGHT_CYAN" "NS-записи (обязательно настроить у регистратора домена):"
print_color "WHITE" "ns1.$DOMAIN.    →    $SERVER_IP"
print_color "WHITE" "ns2.$DOMAIN.    →    $SERVER_IP"
log_info "NS record: ns1.$DOMAIN → $SERVER_IP"
log_info "NS record: ns2.$DOMAIN → $SERVER_IP"

print_separator "-" 80


print_info "❗ После настройки NS-записей у регистратора, изменения вступят через 24-48 часов."
print_info "❗ Проверить можно здесь:"
print_info "   • https://iamroot.tech/dns-lookup/default.aspx?host=$DOMAIN"
print_info "   • https://who.is/whois/$DOMAIN"

# --- Напоминание про PTR ---
print_section "📮 ОБЯЗАТЕЛЬНО: НАСТРОЙКА PTR (rDNS)"

PTR_RECORD=$(echo "$SERVER_IP" | awk -F. '{print $4"."$3"."$2"."$1".in-addr.arpa."}')
print_warning "Обратитесь к вашему хостинг-провайдеру с запросом:"
print_warning "PTR record: $PTR_RECORD    IN    PTR    $DOMAIN."
log_warning "PTR record required: $PTR_RECORD IN PTR $DOMAIN."

print_success "✅ Модуль BIND9 завершён успешно (включая поддомен git.$DOMAIN)"