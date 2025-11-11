#!/bin/bash
# modules/08-web-server.sh - Установка и настройка веб-сервера NGINX
# Часть Mail Server Deployment Module System

# --- Загрузка вспомогательных утилит ---
[[ -z "${UTIL_PRINT_LOADED}" ]] && source ./utils/print.sh 2>/dev/null
[[ -z "${UTIL_LOGGING_LOADED}" ]] && source ./utils/logging.sh 2>/dev/null
[[ -z "${UTIL_FUNCTIONS_LOADED}" ]] && source ./utils/functions.sh 2>/dev/null


# --- Проверка прав root ---
ensure_root

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

# --- Проверка ОС ---
ensure_debian || {
    print_error "Поддерживается только Debian 11+"
    log_error "Unsupported OS. Only Debian 11+ is supported."
    [[ "$FORCE_MODE" != "true" ]] && exit 1
}

# --- Проверка наличия необходимых команд ---
require_command "ip" "определение IP-адресов"
require_command "ufw" "настройка фаервола (опционально)"

# --- Установка NGINX и Certbot ---
print_step "Установка NGINX, Certbot и зависимостей"
if ! command -v nginx &> /dev/null; then
    # Добавляем репозиторий Certbot, если нужно
    if ! apt-cache policy certbot | grep -q "Installed:"; then
        print_info "Добавление репозитория Certbot..."
        apt install -y software-properties-common > /dev/null 2>&1
        add-apt-repository ppa:certbot/certbot -y > /dev/null 2>&1
        apt update -qq > /dev/null 2>&1
    fi

    if apt install -y nginx certbot python3-certbot-nginx > /dev/null 2>&1; then
        print_success "NGINX и Certbot успешно установлены"
        log_info "NGINX and Certbot installed successfully"
    else
        print_error "Не удалось установить NGINX или Certbot"
        log_error "Failed to install NGINX or Certbot"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
else
    print_success "NGINX уже установлен"
    log_info "NGINX is already installed"
fi

# --- Обновление системы (если нужно) ---
if [[ "${AUTO_UPDATE:-true}" == "true" ]]; then
    print_step "Обновление системы (apt upgrade)"
    if apt update -qq && apt upgrade -y > /dev/null 2>&1; then
        print_success "Система обновлена"
        log_info "System packages upgraded"
    else
        print_warning "Не удалось обновить систему — продолжаем"
        log_warn "System upgrade failed — continuing"
    fi
fi

# --- Настройка UFW ---
if [[ "${ENABLE_UFW:-true}" == "true" ]] && command -v ufw &> /dev/null; then
    print_step "Настройка UFW: разрешение HTTP и HTTPS"
    if ufw status | grep -q "Status: active"; then
        # Проверяем, есть ли уже правила
        if ! ufw status | grep -q "Nginx HTTP"; then
            ufw allow 'Nginx HTTP' > /dev/null 2>&1
        fi
        if ! ufw status | grep -q "Nginx HTTPS"; then
            ufw allow 'Nginx HTTPS' > /dev/null 2>&1
        fi
        print_success "Правила UFW для NGINX применены"
        log_info "UFW rules for NGINX applied"
    else
        print_warning "UFW не активен — правила не применены"
        log_warn "UFW is not active — skipping rule application"
    fi
else
    print_warning "UFW отключен или не установлен — пропуск настройки"
    log_warn "UFW disabled or not installed — skipping firewall config"
fi

# --- Создание директории для сайтов ---
print_step "Создание директории для сайтов: /var/www/$DOMAIN"
safe_mkdir "/var/www/$DOMAIN" "www-data:www-data" "755" || {
    print_error "Не удалось создать директорию сайта"
    log_error "Failed to create website directory"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
}

# --- Создание базового index.html ---
print_step "Создание персональной страницы: /var/www/$DOMAIN/index.html"
cat > "/var/www/$DOMAIN/index.html" <<'EOF'
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">

<html xmlns="http://www.w3.org/1999/xhtml">

<head>
    <meta name="google-site-verification" content="IFZCQvbF1-afUpu3LEGEGLeC_3l3mOeQavwsN7_Xrkw" />
    <meta http-equiv="Content-Type" content="text/html; charset=UTF-8" />
    <meta http-equiv="content-language" content="ru, en" />
    <meta http-equiv="Content-Style-Type" content="text/css">

    <meta name="author" lang="en" content="Danil Murashkin" />
    <meta name="author" lang="ru" content="Мурашкин Данил" />

    <meta name="description" content="personal page about me, личная страница обо мне" />
    <meta name="keywords" content="Данил, Мурашкин, Мурашкин Данил, Danil, Murashkin, Danil Murashkin, personal page, личная страница, циататы, статьи, danil@murashkin.info, danil.murashkin@gmail.com, Sizif, Сизиф" />

    <meta name="document-state" content="Dynamic" />
    <meta name="resource-type" content="document" />
    <meta name="revisit" content="7" />

    <meta name="robots" content="all">

    <link rel="shortcut icon" type="image/x-icon" href="/favicon.ico">

    <title>Danil Murashkin</title>
</head>
    
    
    
<body>
    
    
    <div id="page" style="position: absolute;  margin: auto;  top: 0;  right: 0;  bottom: 0;  left: 0; width: 500px; height: 170px; text-align: center; ">

        <font size=6 face="Arial">Sizif?</font><br>
        <font size=3 face="Arial">Yes, I am Sizif.</font>
        <br><br>

        <font size=3 face="Arial">
            <a href ="mailto:danil@murashkin.info" style="text-decoration: none; opacity: 0.50;">
                danil@murashkin.info
            </a>
        </font>
        <br><br><br>

        <span style="opacity:0.30;">
            <font size=3 face="Arial"><i>
                На свете нет ничего такого, что стоило бы наших нервов,
                </i></font><br>
            <font size=3 face="Arial"><i>
                И так много всего, что стоит наших усердий и любви.
                </i></font><br>
        </span>

    </div>
    
    
</body>
    
    
    
</html>
EOF

if [[ $? -eq 0 ]]; then
    chown www-data:www-data "/var/www/$DOMAIN/index.html"
    print_success "Персональная страница создана"
    log_info "Personal index.html created for $DOMAIN"
else
    print_error "Не удалось создать index.html"
    log_error "Failed to create index.html"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# --- Настройка виртуального хоста по умолчанию ---
print_step "Настройка виртуального хоста NGINX для $DOMAIN"
NGINX_SITE_CONF="/etc/nginx/sites-available/$DOMAIN"
NGINX_SITE_ENABLED="/etc/nginx/sites-enabled/$DOMAIN"

cat > "$NGINX_SITE_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;

    server_name $DOMAIN www.$DOMAIN $SERVER_IP;
    root /var/www/$DOMAIN;
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # Запрещаем доступ к скрытым файлам
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }

    # Отключаем версию сервера в заголовках
    server_tokens off;
}
EOF

if [[ $? -eq 0 ]]; then
    print_success "Конфигурация виртуального хоста создана"
    log_info "NGINX virtual host config created: $NGINX_SITE_CONF"
else
    print_error "Не удалось создать конфигурацию виртуального хоста"
    log_error "Failed to create NGINX virtual host config"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# --- Активация сайта ---
print_step "Активация сайта $DOMAIN"
if [[ ! -L "$NGINX_SITE_ENABLED" ]]; then
    ln -s "$NGINX_SITE_CONF" "$NGINX_SITE_ENABLED" && \
        print_success "Сайт активирован" && \
        log_info "Site $DOMAIN enabled"
else
    print_info "Сайт уже активирован — пропуск"
    log_info "Site $DOMAIN already enabled — skipping"
fi

# --- Отключение дефолтного сайта NGINX ---
print_step "Отключение дефолтного сайта NGINX"
if [[ -L /etc/nginx/sites-enabled/default ]]; then
    rm /etc/nginx/sites-enabled/default && \
        print_success "Дефолтный сайт отключён" && \
        log_info "Default NGINX site disabled"
else
    print_info "Дефолтный сайт уже отключён — пропуск"
    log_info "Default NGINX site already disabled — skipping"
fi

# --- Проверка конфигурации NGINX ---
print_step "Проверка конфигурации NGINX: nginx -t"
if nginx -t > /dev/null 2>&1; then
    print_success "Конфигурация NGINX корректна"
    log_info "NGINX configuration test passed"
else
    print_error "Ошибки в конфигурации NGINX"
    log_error "NGINX configuration test failed"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# --- Перезапуск NGINX ---
print_step "Перезапуск службы NGINX"
if systemctl restart nginx > /dev/null 2>&1 && systemctl enable nginx > /dev/null 2>&1; then
    print_success "Служба NGINX перезапущена и включена в автозагрузку"
    log_info "NGINX service restarted and enabled"
else
    print_error "Не удалось перезапустить NGINX"
    log_error "Failed to restart NGINX service"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# --- Проверка статуса службы ---
if systemctl is-active --quiet nginx; then
    print_success "Служба NGINX активна"
    log_info "NGINX service is active"
else
    print_error "Служба NGINX не запущена"
    log_error "NGINX service is not active"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi

# --- Отладочная информация ---
print_section "🔍 ОТЛАДОЧНАЯ ИНФОРМАЦИЯ"

# Вывод IP-адресов
print_step "Текущие IPv4 адреса:"
ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | while read ip_addr; do
    print_color "WHITE" "  → $ip_addr"
    log_debug "IPv4 address: $ip_addr"
done

# Проверка разрешения имени
print_step "Проверка разрешения домена $DOMAIN:"
if dig +short "$DOMAIN" | grep -q "$SERVER_IP"; then
    print_success "Домен $DOMAIN разрешается на $SERVER_IP"
    log_info "Domain $DOMAIN resolves to $SERVER_IP"
else
    print_warning "Домен $DOMAIN не разрешается или не указывает на $SERVER_IP"
    log_warn "Domain $DOMAIN does not resolve to $SERVER_IP — check DNS settings"
fi

# Проверка доступности веб-сервера локально
print_step "Проверка локального доступа к http://$DOMAIN"
if curl -s --connect-timeout 5 "http://$DOMAIN" | grep -q "Welcome to $DOMAIN"; then
    print_success "Локальный доступ к сайту работает"
    log_info "Local HTTP access to $DOMAIN is working"
else
    print_warning "Локальный доступ к сайту не работает — проверьте конфигурацию"
    log_warn "Local HTTP access to $DOMAIN failed — check NGINX config"
fi

# --- Информация для пользователя ---
print_section "🌐 ВАШ САЙТ ГОТОВ"

print_success "✅ Веб-сервер NGINX успешно установлен и настроен"
print_info "Доступ к сайту:"
print_info "   • По IP:    http://$SERVER_IP"
print_info "   • По домену: http://$DOMAIN"
print_info "   • По WWW:    http://www.$DOMAIN"
log_info "Website accessible at: http://$SERVER_IP, http://$DOMAIN, http://www.$DOMAIN"

print_section "📌 ПОЛЕЗНЫЕ КОМАНДЫ"
print_color "DIM" "  Проверить статус: systemctl status nginx"
print_color "DIM" "  Перезагрузить:    systemctl reload nginx"
print_color "DIM" "  Проверить конфиг: nginx -t"
print_color "DIM" "  Логи ошибок:      tail -f /var/log/nginx/error.log"
