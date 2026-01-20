#!/bin/bash
# modules/17-vpn-wireguard.sh - Установка и настройка VPN-сервера WireGuard
# Часть Server Deployment Module System
# Обеспечивает безопасное VPN-подключение с современным протоколом WireGuard

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
if [[ "${ENABLE_VPN:-false}" != "true" ]]; then
    print_warning "VPN WireGuard отключен в конфигурации (ENABLE_VPN=false)"
    log_info "VPN WireGuard installation skipped (ENABLE_VPN=false)"
    exit 0
fi

# --- Проверка переменных ---
print_step "Проверка конфигурации VPN-сервера"

# Устанавливаем значения по умолчанию для WireGuard
VPN_PORT="${VPN_PORT:-51820}"
VPN_SUBNET="${VPN_SUBNET:-10.8.0.0}"
VPN_NETMASK="${VPN_NETMASK:-255.255.255.0}"
VPN_DNS="${VPN_DNS:-8.8.8.8, 8.8.4.4}"
VPN_SUBDOMAIN="${VPN_SUBDOMAIN:-vpn}"
VPN_URL="$VPN_SUBDOMAIN.$DOMAIN"
VPN_MAX_CLIENTS="${VPN_MAX_CLIENTS:-10}"
VPN_DEFAULT_CLIENTS="${VPN_DEFAULT_CLIENTS:-${ADMIN_USER:-admin}::}"

# Конвертация CIDR для WireGuard
VPN_CIDR="24"  # Стандартно для /24 сети

log_info "VPN: $VPN_URL:$VPN_PORT"
log_info "Подсеть: $VPN_SUBNET/$VPN_CIDR"
log_info "DNS: $VPN_DNS"

# --- Проверка ОС ---
ensure_debian || {
    print_error "Поддерживается только Debian 11+"
    log_error "Unsupported OS"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
}

# --- Проверка команд ---
require_command "ip" "определение сетевых интерфейсов"

# --- Установка WireGuard ---
print_step "Установка WireGuard"
if [[ "$DRY_RUN" == "true" ]]; then
    print_warn "(DRY RUN) Установка: wireguard wireguard-tools qrencode"
    log_info "[DRY RUN] Установка пакетов"
else
    log_info "Установка: wireguard wireguard-tools qrencode"
    
    if ! dpkg -l | grep -q "^ii.*wireguard"; then
        if apt install -y wireguard wireguard-tools qrencode >/dev/null 2>&1; then
            print_success "WireGuard установлен"
            log_info "WireGuard установлен успешно"
        else
            print_error "Ошибка установки WireGuard"
            log_error "apt install wireguard failed"
            [[ "$FORCE_MODE" != "true" ]] && exit 1
        fi
    else
        print_success "WireGuard уже установлен"
        log_info "WireGuard is already installed"
    fi
fi

# --- Определение сетевого интерфейса ---
print_step "Определение сетевого интерфейса"
MAIN_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
if [[ -z "$MAIN_INTERFACE" ]]; then
    print_error "Не удалось определить основной сетевой интерфейс"
    log_error "Could not determine main network interface"
    [[ "$FORCE_MODE" != "true" ]] && exit 1
fi
print_info "Основной интерфейс: $MAIN_INTERFACE"
log_info "Основной интерфейс: $MAIN_INTERFACE"

# --- Создание директорий ---
print_step "Создание директорий WireGuard"
if [[ "$DRY_RUN" == "true" ]]; then
    print_warn "(DRY RUN) Создание /etc/wireguard и /root/wireguard-clients"
    log_info "[DRY RUN] Создание директорий"
else
    mkdir -p /etc/wireguard
    mkdir -p /root/wireguard-clients
    chmod 700 /etc/wireguard
    chmod 700 /root/wireguard-clients
    print_success "Директории созданы"
    log_info "Директории WireGuard созданы"
fi

# --- Генерация/восстановление ключей сервера ---
print_step "Генерация/восстановление ключей сервера"
if [[ "$DRY_RUN" == "true" ]]; then
    print_warn "(DRY RUN) Генерация/восстановление серверных ключей"
    log_info "[DRY RUN] Генерация ключей"
else
    config_file="./config/main.conf"
    
    # Проверяем, есть ли сохраненные ключи в конфиге
    if [[ -n "$VPN_SERVER_PRIVATE_KEY" ]] && [[ -n "$VPN_SERVER_PUBLIC_KEY" ]]; then
        print_info "Восстанавливаем серверные ключи из конфигурации"
        log_info "Восстановление ключей из main.conf"
        
        # Создаем ключи из конфига
        echo "$VPN_SERVER_PRIVATE_KEY" > /etc/wireguard/server_private.key
        echo "$VPN_SERVER_PUBLIC_KEY" > /etc/wireguard/server_public.key
        chmod 600 /etc/wireguard/server_private.key
        chmod 644 /etc/wireguard/server_public.key
        
        print_success "Серверные ключи восстановлены из конфигурации"
        log_info "Серверные ключи восстановлены"
        
    elif [[ -f /etc/wireguard/server_private.key ]] && [[ -f /etc/wireguard/server_public.key ]]; then
        print_info "Серверные ключи уже существуют — используем их"
        log_info "Серверные ключи найдены, пропуск генерации"
        
    else
        print_info "Генерация новых серверных ключей"
        log_info "Генерация новых серверных ключей"
        wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key
        chmod 600 /etc/wireguard/server_private.key
        chmod 644 /etc/wireguard/server_public.key
        print_success "Серверные ключи сгенерированы"
        log_info "Серверные ключи созданы"
    fi
fi

# --- Чтение и сохранение ключей ---
if [[ "$DRY_RUN" != "true" ]]; then
    # Используем ключи из конфига если они есть, иначе читаем из файлов
    if [[ -n "$VPN_SERVER_PRIVATE_KEY" ]] && [[ -n "$VPN_SERVER_PUBLIC_KEY" ]]; then
        SERVER_PRIVATE_KEY="$VPN_SERVER_PRIVATE_KEY"
        SERVER_PUBLIC_KEY="$VPN_SERVER_PUBLIC_KEY"
        log_debug "Используем ключи из конфигурации"
    else
        SERVER_PRIVATE_KEY=$(cat /etc/wireguard/server_private.key)
        SERVER_PUBLIC_KEY=$(cat /etc/wireguard/server_public.key)
        log_debug "Используем ключи из файлов"
    fi
    log_debug "Публичный ключ сервера: $SERVER_PUBLIC_KEY"
    
    # Сохраняем ключи в конфиге, если они там отсутствуют
    if [[ -f "$config_file" ]]; then
        keys_updated=false
        
        # Проверяем существование переменной VPN_SERVER_PRIVATE_KEY в файле
        if ! grep -q "^VPN_SERVER_PRIVATE_KEY=" "$config_file"; then
            echo 'VPN_SERVER_PRIVATE_KEY=""' >> "$config_file"
            log_info "Добавлена переменная VPN_SERVER_PRIVATE_KEY в $config_file"
        fi
        
        # Проверяем существование переменной VPN_SERVER_PUBLIC_KEY в файле  
        if ! grep -q "^VPN_SERVER_PUBLIC_KEY=" "$config_file"; then
            echo 'VPN_SERVER_PUBLIC_KEY=""' >> "$config_file"
            log_info "Добавлена переменная VPN_SERVER_PUBLIC_KEY в $config_file"
        fi
        
        # Сохраняем ключи если они пустые
        if [[ -z "$VPN_SERVER_PRIVATE_KEY" ]]; then
            sed -i "s|^VPN_SERVER_PRIVATE_KEY=\".*\"|VPN_SERVER_PRIVATE_KEY=\"$SERVER_PRIVATE_KEY\"|" "$config_file"
            keys_updated=true
            log_info "Серверный приватный ключ сохранён в $config_file"
        fi
        
        if [[ -z "$VPN_SERVER_PUBLIC_KEY" ]]; then
            sed -i "s|^VPN_SERVER_PUBLIC_KEY=\".*\"|VPN_SERVER_PUBLIC_KEY=\"$SERVER_PUBLIC_KEY\"|" "$config_file"
            keys_updated=true
            log_info "Серверный публичный ключ сохранён в $config_file"
        fi
        
        if [[ "$keys_updated" == "true" ]]; then
            print_success "Серверные ключи сохранены в конфигурации"
        fi
        
        # Проверяем соответствие ключей
        if [[ -n "$VPN_SERVER_PRIVATE_KEY" ]] && [[ "$VPN_SERVER_PRIVATE_KEY" != "$SERVER_PRIVATE_KEY" ]]; then
            print_warn "Приватный ключ в конфиге не соответствует текущему"
            log_warn "Private key mismatch between config and files"
        fi
        
        if [[ -n "$VPN_SERVER_PUBLIC_KEY" ]] && [[ "$VPN_SERVER_PUBLIC_KEY" != "$SERVER_PUBLIC_KEY" ]]; then
            print_warn "Публичный ключ в конфиге не соответствует текущему"
            log_warn "Public key mismatch between config and files"
        fi
        
    else
        log_warn "Конфиг файл $config_file не найден, ключи не сохранены"
    fi
fi

# --- Создание конфигурации сервера ---
print_step "Создание конфигурации WireGuard"
if [[ "$DRY_RUN" == "true" ]]; then
    print_warn "(DRY RUN) Создание /etc/wireguard/wg0.conf"
    log_info "[DRY RUN] Создание конфигурации"
else
    # Резервная копия если существует
    if [[ -f /etc/wireguard/wg0.conf ]]; then
        cp /etc/wireguard/wg0.conf /etc/wireguard/wg0.conf.bak.$(date +%Y%m%d_%H%M%S)
        log_info "Создана резервная копия wg0.conf"
    fi
    
    cat > /etc/wireguard/wg0.conf <<EOF
# === WireGuard Server Configuration ===
# Generated by server_script installer
# Domain: $DOMAIN
# Server: $VPN_URL
# Date: $(date)

[Interface]
# Приватный ключ сервера
PrivateKey = $SERVER_PRIVATE_KEY

# Адрес сервера в VPN сети
Address = 10.8.0.1/$VPN_CIDR

# Порт прослушивания
ListenPort = $VPN_PORT

# DNS для клиентов
# PostUp = echo nameserver $VPN_DNS | resolvconf -a %i -m 0 -x
# PostDown = resolvconf -d %i

# Включение NAT и форвардинга
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o $MAIN_INTERFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o $MAIN_INTERFACE -j MASQUERADE

# === Клиенты будут добавлены ниже ===
# Каждый клиент добавляется через [Peer] секцию

EOF

    chmod 600 /etc/wireguard/wg0.conf
    print_success "Конфигурация сервера создана"
    log_info "Файл /etc/wireguard/wg0.conf создан"
fi

# --- Включение IP forwarding ---
print_step "Включение IP forwarding"
if [[ "$DRY_RUN" == "true" ]]; then
    print_warn "(DRY RUN) sysctl net.ipv4.ip_forward=1"
    log_info "[DRY RUN] Включение IP forwarding"
else
    # Временно
    if sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1; then
        print_success "IP forwarding включен (временно)"
        log_info "IP forwarding enabled temporarily"
    fi
    
    # Постоянно
    if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        print_success "IP forwarding включен (постоянно)"
        log_info "IP forwarding enabled permanently in /etc/sysctl.conf"
    else
        print_success "IP forwarding уже включен постоянно"
        log_info "IP forwarding already enabled in /etc/sysctl.conf"
    fi
    
    sysctl -p >/dev/null 2>&1
fi

# --- Создание функции для добавления клиентов ---
create_client_config() {
    local CLIENT_NAME="$1"
    local CLIENT_IP="$2"
    local RESTORE_PRIVATE_KEY="$3"
    local RESTORE_PUBLIC_KEY="$4"
    
    if [[ -z "$CLIENT_NAME" ]] || [[ -z "$CLIENT_IP" ]]; then
        print_error "Не указано имя клиента или IP"
        return 1
    fi
    
    local CLIENT_DIR="/root/wireguard-clients/$CLIENT_NAME"
    mkdir -p "$CLIENT_DIR"
    
    local CLIENT_PRIVATE_KEY
    local CLIENT_PUBLIC_KEY
    
    # Если переданы ключи для восстановления - используем их
    if [[ -n "$RESTORE_PRIVATE_KEY" ]] && [[ -n "$RESTORE_PUBLIC_KEY" ]]; then
        echo "$RESTORE_PRIVATE_KEY" > "$CLIENT_DIR/private.key"
        echo "$RESTORE_PUBLIC_KEY" > "$CLIENT_DIR/public.key"
        chmod 600 "$CLIENT_DIR/private.key"
        
        CLIENT_PRIVATE_KEY="$RESTORE_PRIVATE_KEY"
        CLIENT_PUBLIC_KEY="$RESTORE_PUBLIC_KEY"
        
        log_info "Ключи клиента $CLIENT_NAME восстановлены из VPN_DEFAULT_CLIENTS"
    else
        # Генерация новых ключей клиента
        wg genkey | tee "$CLIENT_DIR/private.key" | wg pubkey > "$CLIENT_DIR/public.key"
        chmod 600 "$CLIENT_DIR/private.key"
        
        CLIENT_PRIVATE_KEY=$(cat "$CLIENT_DIR/private.key")
        CLIENT_PUBLIC_KEY=$(cat "$CLIENT_DIR/public.key")
        
        log_info "Новые ключи сгенерированы для клиента $CLIENT_NAME"
    fi
    
    # Создание конфигурации клиента
    cat > "$CLIENT_DIR/$CLIENT_NAME.conf" <<EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = $CLIENT_IP/$VPN_CIDR
DNS = $VPN_DNS

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $SERVER_IP:$VPN_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
    
    # Добавление клиента в конфигурацию сервера
    cat >> /etc/wireguard/wg0.conf <<EOF

# === Клиент: $CLIENT_NAME ===
[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = $CLIENT_IP/32

EOF
    
    # Генерация QR-кода
    if command -v qrencode &> /dev/null; then
        qrencode -t ansiutf8 < "$CLIENT_DIR/$CLIENT_NAME.conf" > "$CLIENT_DIR/$CLIENT_NAME-qr.txt"
        qrencode -t png -o "$CLIENT_DIR/$CLIENT_NAME-qr.png" < "$CLIENT_DIR/$CLIENT_NAME.conf"
    fi
    
    print_success "Клиент $CLIENT_NAME создан (IP: $CLIENT_IP)"
    log_info "Клиент $CLIENT_NAME создан с IP $CLIENT_IP"
}

# --- Восстановление существующих клиентов или создание первого ---
print_step "Восстановление клиентов"
if [[ "$DRY_RUN" == "true" ]]; then
    print_warn "(DRY RUN) Восстановление/создание клиентов"
    log_info "[DRY RUN] Восстановление клиентов"
else
    restored_clients=0
    
    # Восстанавливаем существующих клиентов
    if [[ -d /root/wireguard-clients ]]; then
        for client_dir in /root/wireguard-clients/*/; do
            if [[ -d "$client_dir" ]]; then
                client_name=$(basename "$client_dir")
                if [[ -f "$client_dir/public.key" ]] && ! grep -q "Клиент: $client_name" /etc/wireguard/wg0.conf; then
                    client_ip=$(grep "Address = " "$client_dir/$client_name.conf" 2>/dev/null | awk '{print $3}' | cut -d'/' -f1)
                    client_public_key=$(cat "$client_dir/public.key")
                    client_private_key=$(cat "$client_dir/private.key")
                    
                    # Обновляем конфигурацию клиента с актуальным серверным ключом
                    cat > "$client_dir/$client_name.conf" <<EOF
[Interface]
PrivateKey = $client_private_key
Address = $client_ip/$VPN_CIDR
DNS = $VPN_DNS

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $SERVER_IP:$VPN_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
                    
                    # Обновляем QR-код
                    if command -v qrencode &> /dev/null; then
                        qrencode -t ansiutf8 < "$client_dir/$client_name.conf" > "$client_dir/$client_name-qr.txt"
                        qrencode -t png -o "$client_dir/$client_name-qr.png" < "$client_dir/$client_name.conf"
                    fi
                    
                    # Добавляем в серверную конфигурацию
                    cat >> /etc/wireguard/wg0.conf <<EOF

# === Клиент: $client_name ===
[Peer]
PublicKey = $client_public_key
AllowedIPs = $client_ip/32

EOF
                    print_success "Восстановлен клиент: $client_name ($client_ip) с обновленным ключом"
                    log_info "Клиент $client_name восстановлен с актуальным серверным ключом"
                    ((restored_clients++))
                fi
            fi
        done
    fi
    
    # Создаём клиентов по умолчанию из VPN_DEFAULT_CLIENTS
    if [[ $restored_clients -eq 0 ]]; then
        print_info "Создание клиентов по умолчанию из VPN_DEFAULT_CLIENTS"
        
        # Парсим VPN_DEFAULT_CLIENTS формата "user1:priv:pub,user2:priv:pub"
        IFS=',' read -ra CLIENTS <<< "$VPN_DEFAULT_CLIENTS"
        client_index=2  # Начинаем с 10.8.0.2
        
        declare -a new_clients_data  # Массив для сохранения обновленных данных
        
        for client_entry in "${CLIENTS[@]}"; do
            IFS=':' read -r client_name client_private client_public <<< "$client_entry"
            
            if [[ -z "$client_name" ]]; then
                continue
            fi
            
            client_ip="10.8.0.$client_index"
            
            # Создаем клиента с восстановлением ключей если они есть
            if [[ -n "$client_private" ]] && [[ -n "$client_public" ]]; then
                create_client_config "$client_name" "$client_ip" "$client_private" "$client_public"
                # Сохраняем с существующими ключами
                new_clients_data+=("$client_name:$client_private:$client_public")
            else
                create_client_config "$client_name" "$client_ip"
                # Читаем сгенерированные ключи
                new_private=$(cat "/root/wireguard-clients/$client_name/private.key")
                new_public=$(cat "/root/wireguard-clients/$client_name/public.key")
                new_clients_data+=("$client_name:$new_private:$new_public")
            fi
            
            ((client_index++))
        done
        
        # Сохраняем обновленные данные клиентов обратно в конфиг
        config_file="./config/main.conf"
        if [[ -f "$config_file" ]] && [[ ${#new_clients_data[@]} -gt 0 ]]; then
            # Формируем новую строку VPN_DEFAULT_CLIENTS
            new_clients_string=$(IFS=','; echo "${new_clients_data[*]}")
            
            if grep -q "^VPN_DEFAULT_CLIENTS=" "$config_file"; then
                sed -i "s|^VPN_DEFAULT_CLIENTS=\".*\"|VPN_DEFAULT_CLIENTS=\"$new_clients_string\"|" "$config_file"
                log_info "VPN_DEFAULT_CLIENTS обновлен с ключами клиентов"
                print_success "Ключи клиентов сохранены в конфигурацию"
            fi
        fi
    fi
fi

# --- Настройка firewall (UFW) ---
if [[ "${ENABLE_UFW:-true}" == "true" ]]; then
    print_step "Настройка UFW firewall"
    if [[ "$DRY_RUN" == "true" ]]; then
        print_warn "(DRY RUN) ufw allow $VPN_PORT/udp"
        log_info "[DRY RUN] Открытие порта $VPN_PORT"
    else
        if command -v ufw &> /dev/null; then
            log_info "Открытие порта $VPN_PORT в UFW"
            if ufw status | grep -q "Status: active"; then
                ufw allow "$VPN_PORT/udp" comment "WireGuard VPN" >/dev/null 2>&1
                ufw reload >/dev/null 2>&1
            else
                ufw allow "$VPN_PORT/udp" comment "WireGuard VPN" >/dev/null 2>&1
                echo "y" | ufw enable >/dev/null 2>&1
            fi
            print_success "Порт $VPN_PORT/udp открыт"
            log_info "UFW: порт $VPN_PORT/udp открыт"
        else
            print_warn "UFW не установлен, пропуск настройки firewall"
            log_warn "UFW not found, skipping firewall setup"
        fi
    fi
fi

# --- Запуск WireGuard ---
print_step "Запуск сервиса WireGuard"
if [[ "$DRY_RUN" == "true" ]]; then
    print_warn "(DRY RUN) systemctl enable/start wg-quick@wg0"
    log_info "[DRY RUN] Запуск WireGuard"
else
    log_info "Включение и запуск WireGuard"
    systemctl enable wg-quick@wg0 >/dev/null 2>&1
    systemctl restart wg-quick@wg0 >/dev/null 2>&1
    sleep 3
    
    if systemctl is-active --quiet wg-quick@wg0; then
        print_success "WireGuard запущен"
        log_info "WireGuard успешно запущен"
    else
        print_error "Ошибка запуска WireGuard"
        log_error "systemctl start wg-quick@wg0 failed"
        journalctl -xeu wg-quick@wg0 --no-pager -n 20 | tee -a "$LOG_FILE"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
fi

# --- Проверка интерфейса ---
print_step "Проверка VPN интерфейса"
if [[ "$DRY_RUN" == "true" ]]; then
    print_warn "(DRY RUN) Проверка интерфейса wg0"
    log_info "[DRY RUN] Проверка интерфейса"
else
    sleep 2
    if ip link show wg0 >/dev/null 2>&1; then
        print_success "Интерфейс wg0 активен"
        log_info "WireGuard интерфейс wg0 создан"
        
        # Показываем статус
        WG_STATUS=$(wg show wg0 2>/dev/null)
        if [[ -n "$WG_STATUS" ]]; then
            log_debug "WireGuard status:\n$WG_STATUS"
        fi
    else
        print_error "Интерфейс wg0 не создан"
        log_error "WireGuard interface wg0 not found"
        [[ "$FORCE_MODE" != "true" ]] && exit 1
    fi
fi

# --- Создание скрипта управления клиентами ---
print_step "Создание скрипта управления клиентами"
if [[ "$DRY_RUN" == "true" ]]; then
    print_warn "(DRY RUN) Создание /usr/local/bin/wg-client"
    log_info "[DRY RUN] Создание скрипта"
else
    cat > /usr/local/bin/wg-client <<'SCRIPT_EOF'
#!/bin/bash
# WireGuard Client Management Script
# Generated by server_script installer

set -e

SERVER_CONF="/etc/wireguard/wg0.conf"
CLIENTS_DIR="/root/wireguard-clients"
SERVER_PUBLIC_KEY=$(cat /etc/wireguard/server_public.key)
SERVER_IP=$(grep "^SERVER_IP=" /root/config/main.conf 2>/dev/null | cut -d'=' -f2 | tr -d '"' || curl -s ifconfig.me || echo "YOUR_SERVER_IP")
VPN_PORT=$(grep "ListenPort" "$SERVER_CONF" | awk '{print $3}')
VPN_DNS="8.8.8.8, 8.8.4.4"

# Функция для получения следующего свободного IP
get_next_ip() {
    local LAST_IP=$(grep "AllowedIPs" "$SERVER_CONF" | grep -oP '10\.8\.0\.\K\d+' | sort -n | tail -1)
    if [[ -z "$LAST_IP" ]]; then
        echo "10.8.0.2"
    else
        echo "10.8.0.$((LAST_IP + 1))"
    fi
}

# Добавление клиента
add_client() {
    local CLIENT_NAME="$1"
    
    if [[ -z "$CLIENT_NAME" ]]; then
        echo "Использование: wg-client add <имя_клиента>"
        exit 1
    fi
    
    if [[ -d "$CLIENTS_DIR/$CLIENT_NAME" ]]; then
        echo "Ошибка: Клиент $CLIENT_NAME уже существует"
        exit 1
    fi
    
    local CLIENT_IP=$(get_next_ip)
    local CLIENT_DIR="$CLIENTS_DIR/$CLIENT_NAME"
    
    mkdir -p "$CLIENT_DIR"
    
    # Генерация ключей
    wg genkey | tee "$CLIENT_DIR/private.key" | wg pubkey > "$CLIENT_DIR/public.key"
    chmod 600 "$CLIENT_DIR/private.key"
    
    local CLIENT_PRIVATE_KEY=$(cat "$CLIENT_DIR/private.key")
    local CLIENT_PUBLIC_KEY=$(cat "$CLIENT_DIR/public.key")
    
    # Сохраняем ключ в конфиг если он существует
    CONFIG_FILE="./config/main.conf"
    if [[ -f "$CONFIG_FILE" ]]; then
        client_key_var="VPN_CLIENT_${CLIENT_NAME^^}_PRIVATE_KEY"
        client_key_var="${client_key_var//-/_}"
        
        # Проверяем существование переменной в файле
        if ! grep -q "^${client_key_var}=" "$CONFIG_FILE"; then
            echo "${client_key_var}=\"\"" >> "$CONFIG_FILE"
            log_info "Добавлена переменная ${client_key_var} в $CONFIG_FILE"
        fi
        
        # Сохраняем ключ клиента
        sed -i "s|^${client_key_var}=\".*\"|${client_key_var}=\"$CLIENT_PRIVATE_KEY\"|" "$CONFIG_FILE"
        log_info "Ключ клиента $CLIENT_NAME сохранён в $CONFIG_FILE как ${client_key_var}"
    fi
    
    # Создание конфигурации клиента
    cat > "$CLIENT_DIR/$CLIENT_NAME.conf" <<EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = $CLIENT_IP/24
DNS = $VPN_DNS

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $SERVER_IP:$VPN_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
    
    # Добавление в конфигурацию сервера
    cat >> "$SERVER_CONF" <<EOF

# === Клиент: $CLIENT_NAME ===
[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = $CLIENT_IP/32

EOF
    
    # Генерация QR-кода
    if command -v qrencode &> /dev/null; then
        qrencode -t ansiutf8 < "$CLIENT_DIR/$CLIENT_NAME.conf" > "$CLIENT_DIR/$CLIENT_NAME-qr.txt"
        qrencode -t png -o "$CLIENT_DIR/$CLIENT_NAME-qr.png" < "$CLIENT_DIR/$CLIENT_NAME.conf"
    fi
    
    # Перезагрузка WireGuard
    systemctl restart wg-quick@wg0
    
    echo "✓ Клиент $CLIENT_NAME создан"
    echo "  IP: $CLIENT_IP"
    echo "  Конфигурация: $CLIENT_DIR/$CLIENT_NAME.conf"
    
    if command -v qrencode &> /dev/null; then
        echo ""
        echo "QR-код для подключения:"
        cat "$CLIENT_DIR/$CLIENT_NAME-qr.txt"
    fi
}

# Удаление клиента
remove_client() {
    local CLIENT_NAME="$1"
    
    if [[ -z "$CLIENT_NAME" ]]; then
        echo "Использование: wg-client remove <имя_клиента>"
        exit 1
    fi
    
    if [[ ! -d "$CLIENTS_DIR/$CLIENT_NAME" ]]; then
        echo "Ошибка: Клиент $CLIENT_NAME не найден"
        exit 1
    fi
    
    local CLIENT_PUBLIC_KEY=$(cat "$CLIENTS_DIR/$CLIENT_NAME/public.key")
    
    # Удаление из конфигурации сервера
    sed -i "/# === Клиент: $CLIENT_NAME ===/,/^$/d" "$SERVER_CONF"
    
    # Удаление директории клиента
    rm -rf "$CLIENTS_DIR/$CLIENT_NAME"
    
    # Перезагрузка WireGuard
    systemctl restart wg-quick@wg0
    
    echo "✓ Клиент $CLIENT_NAME удалён"
}

# Список клиентов
list_clients() {
    echo "Активные клиенты WireGuard:"
    echo ""
    
    if [[ ! -d "$CLIENTS_DIR" ]] || [[ -z "$(ls -A "$CLIENTS_DIR" 2>/dev/null)" ]]; then
        echo "  (нет клиентов)"
        return
    fi
    
    for client_dir in "$CLIENTS_DIR"/*; do
        if [[ -d "$client_dir" ]]; then
            local client_name=$(basename "$client_dir")
            local client_ip=$(grep "Address" "$client_dir/$client_name.conf" 2>/dev/null | awk '{print $3}' | cut -d'/' -f1)
            echo "  • $client_name ($client_ip)"
        fi
    done
}

# Показать конфигурацию клиента
show_client() {
    local CLIENT_NAME="$1"
    
    if [[ -z "$CLIENT_NAME" ]]; then
        echo "Использование: wg-client show <имя_клиента>"
        exit 1
    fi
    
    local CLIENT_CONF="$CLIENTS_DIR/$CLIENT_NAME/$CLIENT_NAME.conf"
    
    if [[ ! -f "$CLIENT_CONF" ]]; then
        echo "Ошибка: Клиент $CLIENT_NAME не найден"
        exit 1
    fi
    
    echo "=== Конфигурация клиента: $CLIENT_NAME ==="
    cat "$CLIENT_CONF"
    echo ""
    
    if [[ -f "$CLIENTS_DIR/$CLIENT_NAME/$CLIENT_NAME-qr.txt" ]]; then
        echo "=== QR-код ==="
        cat "$CLIENTS_DIR/$CLIENT_NAME/$CLIENT_NAME-qr.txt"
    fi
}

# Статус WireGuard
status() {
    echo "=== Статус WireGuard ==="
    systemctl status wg-quick@wg0 --no-pager
    echo ""
    echo "=== Подключённые пиры ==="
    wg show wg0
}

# Главное меню
case "${1:-}" in
    add)
        add_client "$2"
        ;;
    remove|delete|del)
        remove_client "$2"
        ;;
    list|ls)
        list_clients
        ;;
    show)
        show_client "$2"
        ;;
    status)
        status
        ;;
    *)
        echo "Управление клиентами WireGuard VPN"
        echo ""
        echo "Использование: wg-client <команда> [параметры]"
        echo ""
        echo "Команды:"
        echo "  add <имя>      - Добавить нового клиента"
        echo "  remove <имя>   - Удалить клиента"
        echo "  list           - Показать список клиентов"
        echo "  show <имя>     - Показать конфигурацию клиента"
        echo "  status         - Показать статус сервера"
        echo ""
        echo "Примеры:"
        echo "  wg-client add laptop"
        echo "  wg-client show laptop"
        echo "  wg-client list"
        echo "  wg-client remove laptop"
        exit 1
        ;;
esac
SCRIPT_EOF

    chmod +x /usr/local/bin/wg-client
    print_success "Скрипт управления создан: /usr/local/bin/wg-client"
    log_info "Скрипт /usr/local/bin/wg-client создан"
fi

# --- Итоговая информация ---
print_step "Информация о VPN-сервере"
print_info "Сервер:  $VPN_URL (или $SERVER_IP)"
print_info "Порт:    $VPN_PORT/udp"
print_info "Подсеть: $VPN_SUBNET/$VPN_CIDR"

if [[ "$DRY_RUN" != "true" ]]; then
    print_info ""
    print_info "Созданные клиенты по умолчанию:"
    
    # Парсим VPN_DEFAULT_CLIENTS для показа списка
    IFS=',' read -ra CLIENTS <<< "$VPN_DEFAULT_CLIENTS"
    for client_entry in "${CLIENTS[@]}"; do
        IFS=':' read -r client_name _ _ <<< "$client_entry"
        if [[ -n "$client_name" ]] && [[ -d "/root/wireguard-clients/$client_name" ]]; then
            client_ip=$(grep "Address = " "/root/wireguard-clients/$client_name/$client_name.conf" 2>/dev/null | awk '{print $3}' | cut -d'/' -f1)
            print_info "  • $client_name ($client_ip)"
            print_info "    Конфигурация: /root/wireguard-clients/$client_name/"
        fi
    done
    
    # Показываем QR-код для первого клиента
    IFS=':' read -r first_client _ _ <<< "${CLIENTS[0]}"
    if [[ -n "$first_client" ]] && [[ -f "/root/wireguard-clients/$first_client/$first_client-qr.txt" ]]; then
        print_info ""
        print_info "QR-код для подключения ($first_client):"
        cat "/root/wireguard-clients/$first_client/$first_client-qr.txt"
    fi
fi

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "WireGuard VPN настроен:"
log_info "  URL: $VPN_URL:$VPN_PORT"
log_info "  Подсеть: $VPN_SUBNET/$VPN_CIDR"

# Логируем всех клиентов
if [[ "$DRY_RUN" != "true" ]]; then
    IFS=',' read -ra CLIENTS <<< "$VPN_DEFAULT_CLIENTS"
    for client_entry in "${CLIENTS[@]}"; do
        IFS=':' read -r client_name _ _ <<< "$client_entry"
        if [[ -n "$client_name" ]]; then
            log_info "  Клиент: $client_name"
        fi
    done
fi
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# --- Команды управления ---
print_info ""
print_info "Управление WireGuard:"
print_info "  systemctl status wg-quick@wg0"
print_info "  systemctl restart wg-quick@wg0"
print_info "  wg show wg0"
print_info ""
print_info "Управление клиентами:"
print_info "  wg-client add <имя>       - Добавить клиента"
print_info "  wg-client list            - Список клиентов"
print_info "  wg-client show <имя>      - Показать конфигурацию"
print_info "  wg-client remove <имя>    - Удалить клиента"
print_info "  wg-client status          - Статус сервера"
print_info ""
print_info "Конфигурации клиентов:"
print_info "  /root/wireguard-clients/"

print_success "✅ Модуль VPN-сервера (WireGuard) завершён"
log_info "Модуль 17-vpn-wireguard.sh завершён успешно"
