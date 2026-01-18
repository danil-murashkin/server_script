#!/bin/bash
# modules/99-system-check.sh - Финальная проверка системы и вывод итогов
# Часть Mail Server Deployment Module System

# --- Загрузка вспомогательных утилит ---
[[ -z "${UTIL_PRINT_LOADED}" ]] && source ./utils/print.sh 2>/dev/null
[[ -z "${UTIL_LOGGING_LOADED}" ]] && source ./utils/logging.sh 2>/dev/null
[[ -z "${UTIL_FUNCTIONS_LOADED}" ]] && source ./utils/functions.sh 2>/dev/null

# --- Проверка прав root ---
ensure_root

# --- Загружаем конфиг, если нужно ---
load_config || {
    print_error "Не удалось загрузить конфигурацию. Убедитесь, что ./config/main.conf существует."
    log_error "Failed to load required configuration"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
}

# --- Проверка переменных ---
for var in DOMAIN SERVER_IP ADMIN_EMAIL ADMIN_PASSWORD; do
    if [[ -z "${!var}" ]]; then
        print_error "Переменная $var не задана"
        log_error "$var is not set"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
done

ADMIN_USER="${ADMIN_USER:-webadmin}"

print_header "Финальная проверка системы"

# --- Массивы для хранения результатов ---
declare -a SERVICES_OK=()
declare -a SERVICES_FAIL=()
declare -a PORTS_OK=()
declare -a PORTS_FAIL=()
declare -a CONFIGS_OK=()
declare -a CONFIGS_FAIL=()

# --- Функция проверки службы ---
check_service() {
    local service="$1"
    local description="$2"
    
    if systemctl is-active --quiet "$service"; then
        SERVICES_OK+=("$description")
        log_info "Service OK: $service"
        return 0
    else
        SERVICES_FAIL+=("$description")
        log_warn "Service FAIL: $service"
        return 1
    fi
}

# --- Функция проверки порта ---
check_port() {
    local port="$1"
    local description="$2"
    
    if ss -tlnp | grep -q ":$port "; then
        PORTS_OK+=("$description ($port)")
        log_info "Port OK: $port"
        return 0
    else
        PORTS_FAIL+=("$description ($port)")
        log_warn "Port FAIL: $port"
        return 1
    fi
}

# --- Функция проверки конфигурации ---
check_config() {
    local command="$1"
    local description="$2"
    
    if eval "$command" >/dev/null 2>&1; then
        CONFIGS_OK+=("$description")
        log_info "Config OK: $description"
        return 0
    else
        CONFIGS_FAIL+=("$description")
        log_warn "Config FAIL: $description"
        return 1
    fi
}

# --- Проверка базовых служб ---
print_step "Проверка системных служб"

check_service "nginx" "Веб-сервер NGINX"
check_service "postgresql" "База данных PostgreSQL"
check_service "php8.2-fpm" "PHP-FPM 8.2"

if systemctl list-unit-files | grep -q "named.service"; then
    check_service "named" "DNS сервер BIND9"
fi

# --- Проверка почтовых служб ---
print_step "Проверка почтовых служб"

check_service "postfix" "SMTP сервер Postfix"
check_service "dovecot" "IMAP/POP3 сервер Dovecot"

if systemctl list-unit-files | grep -q "opendkim.service"; then
    check_service "opendkim" "DKIM подписи OpenDKIM"
fi

# --- Проверка портов ---
print_step "Проверка открытых портов"

check_port "80" "HTTP"
check_port "443" "HTTPS" || true  # Может отсутствовать без SSL
check_port "25" "SMTP"
check_port "587" "SMTP Submission"
check_port "993" "IMAPS"
check_port "143" "IMAP"
check_port "53" "DNS" || true  # Может отсутствовать если DNS не установлен

# --- Проверка конфигураций ---
print_step "Проверка конфигураций"

check_config "nginx -t" "NGINX конфигурация"
check_config "postfix check" "Postfix конфигурация"
check_config "dovecot -n" "Dovecot конфигурация"

if command -v named-checkconf &> /dev/null; then
    check_config "named-checkconf" "BIND9 конфигурация"
fi

# --- Проверка SSL сертификатов ---
print_step "Проверка SSL сертификатов"

if [[ "${ENABLE_SSL:-true}" == "true" ]]; then
    # Получаем пути к сертификатам для основного домена
    SSL_CERT=$(get_ssl_cert_path "$DOMAIN")
    SSL_KEY=$(get_ssl_key_path "$DOMAIN")
    
    if [[ -f "$SSL_CERT" ]] && [[ -f "$SSL_KEY" ]]; then
        CONFIGS_OK+=("SSL сертификаты ($SSL_PROVIDER)")
        log_info "SSL certificates found: $SSL_PROVIDER"
        
        # Проверяем срок действия сертификата
        if openssl x509 -in "$SSL_CERT" -noout -checkend 0 2>/dev/null; then
            CONFIGS_OK+=("SSL сертификат действителен")
            log_info "SSL certificate is valid"
            
            # Получаем дату истечения
            CERT_EXPIRY=$(openssl x509 -in "$SSL_CERT" -noout -enddate 2>/dev/null | cut -d= -f2)
            if [[ -n "$CERT_EXPIRY" ]]; then
                log_info "SSL certificate expires: $CERT_EXPIRY"
            fi
        else
            CONFIGS_FAIL+=("SSL сертификат истёк")
            log_warn "SSL certificate has expired"
        fi
    else
        CONFIGS_FAIL+=("SSL сертификаты не найдены")
        log_warn "SSL certificates not found"
    fi
else
    log_info "SSL disabled in configuration"
fi

# --- Проверка баз данных ---
print_step "Проверка подключений к базам данных"

DB_NAME="${DOMAIN//./_}"
if PGPASSWORD="$ADMIN_PASSWORD" psql -h localhost -U "$ADMIN_USER" -d "$DB_NAME" -c "\q" 2>/dev/null; then
    CONFIGS_OK+=("PostgreSQL подключение")
    log_info "Database connection OK"
else
    CONFIGS_FAIL+=("PostgreSQL подключение")
    log_warn "Database connection FAIL"
fi

# --- Проверка веб-интерфейсов ---
print_step "Проверка веб-интерфейсов"

# PostfixAdmin
if [[ -d "/var/www/mailadmin.$DOMAIN" ]] && [[ -f "/var/www/mailadmin.$DOMAIN/public/index.php" ]]; then
    CONFIGS_OK+=("PostfixAdmin установлен")
    log_info "PostfixAdmin installed"
else
    CONFIGS_FAIL+=("PostfixAdmin установлен")
    log_warn "PostfixAdmin not found"
fi

# Roundcube
if [[ -d "/var/www/roundcube" ]] && [[ -f "/var/www/roundcube/index.php" ]]; then
    CONFIGS_OK+=("Roundcube установлен")
    log_info "Roundcube installed"
else
    CONFIGS_FAIL+=("Roundcube установлен")
    log_warn "Roundcube not found"
fi

# NextCloud
if [[ "${ENABLE_NEXTCLOUD:-false}" == "true" ]]; then
    if [[ -d "/var/www/nextcloud" ]] && [[ -f "/var/www/nextcloud/occ" ]]; then
        CONFIGS_OK+=("NextCloud установлен")
        log_info "NextCloud installed"
    else
        CONFIGS_FAIL+=("NextCloud установлен")
        log_warn "NextCloud not found"
    fi
fi

# --- Проверка DNS записей ---
print_step "Проверка DNS записей"

if command -v dig &> /dev/null; then
    # Проверяем основную A запись
    if dig +short "$DOMAIN" | grep -q "$SERVER_IP"; then
        CONFIGS_OK+=("DNS A запись")
        log_info "DNS A record OK"
    else
        CONFIGS_FAIL+=("DNS A запись")
        log_warn "DNS A record not found or incorrect"
    fi
    
    # Проверяем MX запись
    if dig +short MX "$DOMAIN" | grep -q "mail.$DOMAIN"; then
        CONFIGS_OK+=("DNS MX запись")
        log_info "DNS MX record OK"
    else
        CONFIGS_FAIL+=("DNS MX запись")
        log_warn "DNS MX record not found"
    fi
    
    # Проверяем DKIM запись
    if dig +short TXT "mail._domainkey.$DOMAIN" | grep -q "v=DKIM1"; then
        CONFIGS_OK+=("DKIM DNS запись")
        log_info "DKIM DNS record OK"
    else
        CONFIGS_FAIL+=("DKIM DNS запись")
        log_warn "DKIM DNS record not found (может потребоваться время для распространения)"
    fi
fi

# --- Тест отправки почты ---
print_step "Тест отправки тестового письма"

if echo "Тестовое письмо от сервера $(hostname) в $(date)" | \
   sendmail -f "postmaster@$DOMAIN" "$ADMIN_EMAIL" 2>/dev/null; then
    CONFIGS_OK+=("Отправка почты")
    log_info "Test email sent successfully"
else
    CONFIGS_FAIL+=("Отправка почты")
    log_warn "Test email failed"
fi

# --- Подсчет результатов ---
TOTAL_SERVICES=$((${#SERVICES_OK[@]} + ${#SERVICES_FAIL[@]}))
TOTAL_PORTS=$((${#PORTS_OK[@]} + ${#PORTS_FAIL[@]}))
TOTAL_CONFIGS=$((${#CONFIGS_OK[@]} + ${#CONFIGS_FAIL[@]}))

SERVICES_SUCCESS_RATE=$((${#SERVICES_OK[@]} * 100 / TOTAL_SERVICES))
PORTS_SUCCESS_RATE=$((${#PORTS_OK[@]} * 100 / TOTAL_PORTS))
CONFIGS_SUCCESS_RATE=$((${#CONFIGS_OK[@]} * 100 / TOTAL_CONFIGS))

OVERALL_SUCCESS_RATE=$(((SERVICES_SUCCESS_RATE + PORTS_SUCCESS_RATE + CONFIGS_SUCCESS_RATE) / 3))

# --- Вывод результатов проверки ---
print_header "Результаты проверки системы"

print_info "Службы: ${#SERVICES_OK[@]}/${TOTAL_SERVICES} ($SERVICES_SUCCESS_RATE%)"
print_info "Порты: ${#PORTS_OK[@]}/${TOTAL_PORTS} ($PORTS_SUCCESS_RATE%)"
print_info "Конфигурации: ${#CONFIGS_OK[@]}/${TOTAL_CONFIGS} ($CONFIGS_SUCCESS_RATE%)"
print_info "Общий результат: $OVERALL_SUCCESS_RATE%"

if [[ ${#SERVICES_FAIL[@]} -gt 0 ]]; then
    print_warning "Проблемные службы:"
    for service in "${SERVICES_FAIL[@]}"; do
        print_info "  - $service"
    done
fi

if [[ ${#PORTS_FAIL[@]} -gt 0 ]]; then
    print_warning "Недоступные порты:"
    for port in "${PORTS_FAIL[@]}"; do
        print_info "  - $port"
    done
fi

if [[ ${#CONFIGS_FAIL[@]} -gt 0 ]]; then
    print_warning "Проблемы с конфигурацией:"
    for config in "${CONFIGS_FAIL[@]}"; do
        print_info "  - $config"
    done
fi

# --- Итоговый статус ---
if [[ $OVERALL_SUCCESS_RATE -ge 90 ]]; then
    print_success "Система готова к работе!"
    SYSTEM_STATUS="ГОТОВ"
elif [[ $OVERALL_SUCCESS_RATE -ge 70 ]]; then
    print_warning "Система работает с незначительными проблемами"
    SYSTEM_STATUS="ЧАСТИЧНО ГОТОВ"
else
    print_error "Система требует внимания администратора"
    SYSTEM_STATUS="ТРЕБУЕТ НАСТРОЙКИ"
fi

# --- ФИНАЛЬНЫЙ ОТЧЕТ ---
print_section "ИТОГОВЫЙ ОТЧЕТ УСТАНОВКИ"

print_success "Сервер развернут: $DOMAIN"
print_info "Статус системы: $SYSTEM_STATUS"
print_info "IP адрес: $SERVER_IP"
print_info "Дата установки: $(date '+%Y-%m-%d %H:%M:%S')"

print_section "ДОСТУПНЫЕ СЕРВИСЫ"

# Определяем протокол в зависимости от наличия SSL
if [[ "${ENABLE_SSL:-true}" == "true" ]] && ss -tlnp | grep -q ":443 "; then
    PROTOCOL="https"
    SSL_STATUS="🔒 SSL активен"
else
    PROTOCOL="http"
    SSL_STATUS="⚠️  SSL не настроен"
fi

print_info "$SSL_STATUS"
print_info ""

print_info "Основной сайт:"
print_info "  $PROTOCOL://$DOMAIN"

print_info ""
print_info "Управление почтой (PostfixAdmin):"
print_info "  $PROTOCOL://mailadmin.$DOMAIN"

print_info ""
print_info "Веб-почта (Roundcube):"
print_info "  $PROTOCOL://webmail.$DOMAIN"

if [[ "${ENABLE_GITEA:-false}" == "true" ]]; then
    GITEA_DOMAIN="${GITEA_SUBDOMAIN:-git}.$DOMAIN"
    print_info ""
    print_info "Git-сервер (Gitea):"
    print_info "  $PROTOCOL://$GITEA_DOMAIN"
fi

if [[ "${ENABLE_NEXTCLOUD:-false}" == "true" ]]; then
    NEXTCLOUD_DOMAIN="${NEXTCLOUD_SUBDOMAIN:-cloud}.$DOMAIN"
    print_info ""
    print_info "Облачное хранилище (NextCloud):"
    print_info "  $PROTOCOL://$NEXTCLOUD_DOMAIN"
fi

# Показываем информацию о SSL провайдере
if [[ "${ENABLE_SSL:-true}" == "true" ]]; then
    print_info ""
    case "$SSL_PROVIDER" in
        "letsencrypt")
            print_info "SSL Провайдер: Let's Encrypt (автопродление)"
            ;;
        "self-signed")
            print_info "SSL Провайдер: Self-Signed (самоподписанный)"
            print_warning "  ⚠️  Браузеры покажут предупреждение безопасности"
            ;;
        "custom")
            print_info "SSL Провайдер: Custom (пользовательский)"
            ;;
    esac
fi

print_section "УЧЕТНЫЕ ДАННЫЕ"

print_info "Администратор PostfixAdmin:"
print_info "  Email: $ADMIN_EMAIL"
print_info "  Пароль: ADMIN_PASSWORD"

print_info ""
print_info "Системный пользователь:"
print_info "  Пользователь: $ADMIN_USER"
print_info "  Пароль: ADMIN_PASSWORD"

print_info ""
print_info "База данных PostgreSQL:"
print_info "  Пользователь: $ADMIN_USER"
print_info "  База: ${DOMAIN//./_}"
print_info "  Пароль: ADMIN_PASSWORD"

if [[ "${ENABLE_GITEA:-false}" == "true" ]]; then
    print_info ""
    print_info "Gitea:"
    print_info "  Логин: ${GITEA_ADMIN_USER:-gitadmin}"
    print_info "  Пароль: ADMIN_PASSWORD"
fi

if [[ "${ENABLE_NEXTCLOUD:-false}" == "true" ]]; then
    print_info ""
    print_info "NextCloud:"
    print_info "  Логин: ${NEXTCLOUD_ADMIN_USER:-admin}"
    print_info "  Пароль: ADMIN_PASSWORD"
    print_info "  Данные: ${NEXTCLOUD_DATA_DIR:-/var/www/nextcloud-data}"
fi

print_section "НАСТРОЙКА ПОЧТОВОГО КЛИЕНТА"

print_info "Входящая почта (IMAP):"
print_info "  Сервер:       mail.$DOMAIN"
if [[ "${ENABLE_SSL:-true}" == "true" ]] && ss -tlnp | grep -q ":443 "; then
    print_info "  Порт:         993 (рекомендуется)"
    print_info "  Безопасность: SSL/TLS"
else
    print_info "  Порт:         143"
    print_info "  Безопасность: STARTTLS (если доступно)"
fi
print_info "  Имя:          полный email (user@$DOMAIN)"
print_info "  Пароль:       пароль почтового ящика"

print_info ""
print_info "Исходящая почта (SMTP):"
print_info "  Сервер:        mail.$DOMAIN"
print_info "  Порт:          587 (рекомендуется)"
print_info "  Безопасность:  STARTTLS"
print_info "  Аутентификация: Обязательна"
print_info "  Имя:           полный email (user@$DOMAIN)"
print_info "  Пароль:        пароль почтового ящика"

if [[ "${ENABLE_SSL:-true}" != "true" ]] || ! ss -tlnp | grep -q ":443 "; then
    print_info ""
    print_warning "⚠️  SSL не настроен - почтовый трафик может быть не защищён"
    print_info "Рекомендуется настроить SSL через модуль 04-certificates.sh"
fi

print_section "СЛЕДУЮЩИЕ ШАГИ"

print_info "1. Настройте DNS записи у регистратора домена:"
print_info "   NS записи: ns1.$DOMAIN и ns2.$DOMAIN -> $SERVER_IP"

print_info ""
print_info "2. Дождитесь распространения DNS (24-48 часов)"

print_info ""
print_info "3. Создайте почтовые ящики через PostfixAdmin:"
print_info "   http://mailadmin.$DOMAIN"

print_info ""
print_info "4. Проверьте работу почты:"
print_info "   https://mail-tester.com"
print_info "   https://mxtoolbox.com"

if [[ $OVERALL_SUCCESS_RATE -lt 90 ]]; then
    print_info ""
    print_info "5. Исправьте выявленные проблемы:"
    print_info "   Проверьте логи: tail -f /var/log/mail.log"
    print_info "   Перезапустите службы: systemctl restart postfix dovecot"
fi

if [[ "${ENABLE_SSL:-true}" == "true" ]] && ss -tlnp | grep -q ":443 "; then
    print_section "ПРОВЕРКА SSL"
    
    print_info "Проверить SSL конфигурацию:"
    print_info "  https://www.ssllabs.com/ssltest/analyze.html?d=$DOMAIN"
    
    print_info ""
    print_info "Проверить сертификат локально:"
    print_info "  openssl s_client -connect $DOMAIN:443 -servername $DOMAIN"
    
    print_info ""
    print_info "Информация о сертификате:"
    print_info "  openssl x509 -in $(get_ssl_cert_path "$DOMAIN") -noout -text"
    
    case "$SSL_PROVIDER" in
        "letsencrypt")
            print_info ""
            print_info "Управление Let's Encrypt:"
            print_info "  certbot certificates           # Список сертификатов"
            print_info "  certbot renew --dry-run        # Тест продления"
            print_info "  certbot renew                  # Продление вручную"
            ;;
        "self-signed")
            print_info ""
            print_warning "⚠️  Используются самоподписанные сертификаты"
            print_info "Для продакшена рекомендуется использовать Let's Encrypt"
            ;;
    esac
fi

print_section "ПОЛЕЗНЫЕ КОМАНДЫ"

print_info "Проверка статуса служб:"
print_info "  systemctl status nginx postfix dovecot postgresql"

print_info ""
print_info "Просмотр логов:"
print_info "  tail -f /var/log/mail.log"
print_info "  tail -f /var/log/nginx/error.log"
print_info "  tail -f $LOG_FILE"

print_info ""
print_info "Управление DNS:"
print_info "  rndc reload $DOMAIN"
print_info "  dig @localhost $DOMAIN"

print_info ""
print_info "Тестирование почты:"
print_info "  echo 'Test' | mail -s 'Test' user@$DOMAIN"
print_info "  mailq  # очередь писем"

print_section "ПОДДЕРЖКА"

print_info "Документация:"
print_info "  https://github.com/danil-murashkin/server_script"

print_info ""
print_info "Логи установки:"
print_info "  $LOG_FILE"

# --- Дублирование итогового отчета в лог-файл ---
if [[ "${ENABLE_LOG_FILE:-true}" == "true" ]]; then
    {
        echo ""
        echo "=================================================="
        echo "ИТОГОВЫЙ ОТЧЕТ УСТАНОВКИ"
        echo "=================================================="
        echo "Сервер развернут: $DOMAIN"
        echo "Статус системы: $SYSTEM_STATUS"
        echo "IP адрес: $SERVER_IP"
        echo "Дата установки: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        echo "ДОСТУПНЫЕ СЕРВИСЫ"
        echo ""

        if [[ "${ENABLE_SSL:-true}" == "true" ]] && ss -tlnp | grep -q ":443 "; then
            PROTOCOL="https"
            echo "SSL Status: Enabled ($SSL_PROVIDER)"
        else
            PROTOCOL="http"
            echo "SSL Status: Disabled"
        fi
        echo ""

        echo "Основной сайт:"
        echo "  $PROTOCOL://$DOMAIN"
        echo ""
        echo "Управление почтой (PostfixAdmin):"
        echo "  $PROTOCOL://mailadmin.$DOMAIN"
        echo ""
        echo "Веб-почта (Roundcube):"
        echo "  $PROTOCOL://webmail.$DOMAIN"

        if [[ "${ENABLE_GITEA:-false}" == "true" ]]; then
            GITEA_DOMAIN="${GITEA_SUBDOMAIN:-git}.$DOMAIN"
            echo ""
            echo "Git-сервер (Gitea):"
            echo "  $PROTOCOL://$GITEA_DOMAIN"
        fi

        if [[ "${ENABLE_NEXTCLOUD:-false}" == "true" ]]; then
            NEXTCLOUD_DOMAIN="${NEXTCLOUD_SUBDOMAIN:-cloud}.$DOMAIN"
            echo ""
            echo "Облачное хранилище (NextCloud):"
            echo "  $PROTOCOL://$NEXTCLOUD_DOMAIN"
        fi
        
        echo ""
        echo "УЧЕТНЫЕ ДАННЫЕ"
        echo ""
        echo "Администратор PostfixAdmin:"
        echo "  Email: $ADMIN_EMAIL"
        echo "  Пароль: ADMIN_PASSWORD"
        echo ""
        echo "Системный пользователь:"
        echo "  Пользователь: $ADMIN_USER"
        echo "  Пароль: ADMIN_PASSWORD"
        echo ""
        echo "База данных PostgreSQL:"
        echo "  Пользователь: $ADMIN_USER"
        echo "  База: ${DOMAIN//./_}"
        echo "  Пароль: ADMIN_PASSWORD"
        
        if [[ "${ENABLE_NEXTCLOUD:-false}" == "true" ]]; then
            echo ""
            echo "NextCloud:"
            echo "  Логин: ${NEXTCLOUD_ADMIN_USER:-admin}"
            echo "  Пароль: ADMIN_PASSWORD"
            echo "  Данные: ${NEXTCLOUD_DATA_DIR:-/var/www/nextcloud-data}"
        fi
        
        if PGPASSWORD="$ADMIN_PASSWORD" psql -h localhost -U "$ADMIN_USER" -d "${DOMAIN//./_}" \
           -tAc "SELECT COUNT(*) FROM mailbox WHERE username='test@$DOMAIN';" 2>/dev/null | grep -q "1"; then
            echo ""
            echo "Тестовый почтовый ящик:"
            echo "  Email: test@$DOMAIN"
            echo "  Пароль: test123"
        fi
        echo ""
        echo "НАСТРОЙКА ПОЧТОВОГО КЛИЕНТА"
        echo ""
        echo "Входящая почта (IMAP):"
        echo "  Сервер: $DOMAIN"
        echo "  Порт: 993 (SSL) или 143 (STARTTLS)"
        echo "  Безопасность: SSL/TLS"
        echo ""
        echo "Исходящая почта (SMTP):"
        echo "  Сервер: $DOMAIN"
        echo "  Порт: 587 (STARTTLS) или 465 (SSL)"
        echo "  Аутентификация: Обязательна"
        echo "  Безопасность: STARTTLS или SSL/TLS"
        echo ""
        echo "СЛЕДУЮЩИЕ ШАГИ"
        echo ""
        echo "1. Настройте DNS записи у регистратора домена:"
        echo "   NS записи: ns1.$DOMAIN и ns2.$DOMAIN -> $SERVER_IP"
        echo ""
        echo "2. Дождитесь распространения DNS (24-48 часов)"
        echo ""
        echo "3. Создайте почтовые ящики через PostfixAdmin:"
        echo "   http://mailadmin.$DOMAIN"
        echo ""
        echo "4. Проверьте работу почты:"
        echo "   https://mail-tester.com"
        echo "   https://mxtoolbox.com"
        
        if [[ $OVERALL_SUCCESS_RATE -lt 90 ]]; then
            echo ""
            echo "5. Исправьте выявленные проблемы:"
            echo "   Проверьте логи: tail -f /var/log/mail.log"
            echo "   Перезапустите службы: systemctl restart postfix dovecot"
        fi
        echo ""
        echo "ПОЛЕЗНЫЕ КОМАНДЫ"
        echo ""
        echo "Проверка статуса служб:"
        echo "  systemctl status nginx postfix dovecot postgresql"
        echo ""
        echo "Просмотр логов:"
        echo "  tail -f /var/log/mail.log"
        echo "  tail -f /var/log/nginx/error.log"
        echo "  tail -f $LOG_FILE"
        echo ""
        echo "Управление DNS:"
        echo "  rndc reload $DOMAIN"
        echo "  dig @localhost $DOMAIN"
        echo ""
        echo "Тестирование почты:"
        echo "  echo 'Test' | mail -s 'Test' user@$DOMAIN"
        echo "  mailq  # очередь писем"
        echo ""
        echo "ПОДДЕРЖКА"
        echo ""
        echo "Документация:"
        echo "  https://github.com/danil-murashkin/server_script"
        echo ""
        echo "Логи установки:"
        echo "  $LOG_FILE"
        echo ""
        echo "Установка завершена! Система $SYSTEM_STATUS."
        echo "=================================================="
    } >> "$LOG_FILE"
fi

print_success "Установка завершена! Система $SYSTEM_STATUS."

log_info "System check completed. Overall success rate: $OVERALL_SUCCESS_RATE%. Status: $SYSTEM_STATUS"
log_info "Installation summary logged. Services OK: ${#SERVICES_OK[@]}, Configs OK: ${#CONFIGS_OK[@]}, Ports OK: ${#PORTS_OK[@]}"
    