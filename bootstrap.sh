#!/bin/bash

# bootstrap.sh - Скачивание и запуск установки
# Часть Git Server Deployment Module System

set -euo pipefail  # Строгий режим для лучшей диагностики

# Цвета
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[38;5;111m"
BOLD="\033[1m"
RESET="\033[0m"

print_info()   { echo -e "${BLUE}${BOLD}ℹ️  [INFO]${RESET}  $*"; }
print_success(){ echo -e "${GREEN}${BOLD}✅ [OK]${RESET}    $*"; }
print_warning(){ echo -e "${YELLOW}${BOLD}⚠️  [WARN]${RESET}  $*"; }
print_error()  { echo -e "${RED}${BOLD}❌ [ERROR]${RESET} $*"; }
print_step()   { echo -e "${BLUE}${BOLD}🔧 [STEP]${RESET}  $*"; }

# Парсинг параметров
INSTALL_DIR="${HOME}"
INSTALL_ARGS=()  # Массив для аргументов install.sh
BACKGROUND_MODE=false

for arg in "$@"; do
    case $arg in
        --install_dir=*)
            INSTALL_DIR="${arg#*=}"
            # Не добавляем в INSTALL_ARGS - это параметр только для bootstrap
            ;;
        --install|-install)
            AUTO_INSTALL=true
            # Не добавляем в INSTALL_ARGS - это параметр только для bootstrap
            ;;
        --background)
            BACKGROUND_MODE=true
            ;;
        *)
            # Все остальные параметры передаем в install.sh
            INSTALL_ARGS+=("$arg")
            ;;
    esac
done

# Настройки репозитория
REPO_BRANCH="${REPO_BRANCH:-main}"
REPO_URL="https://github.com/danil-murashkin/server_script.git"
REPO_URL_ALT="https://raw.githubusercontent.com/danil-murashkin/server_script/${REPO_BRANCH}"
INSTALL_SCRIPT_DIR="$INSTALL_DIR/server_script"
INSTALL_SCRIPT="$INSTALL_SCRIPT_DIR/install.sh"

# Создаем директории и их очистку заранее
# rm -rf "$INSTALL_SCRIPT_DIR"
mkdir -p "$INSTALL_SCRIPT_DIR" || {
    print_error "Не удалось создать: $INSTALL_SCRIPT_DIR"
    exit 1
}
mkdir -p "$INSTALL_SCRIPT_DIR/logs" 2>/dev/null || true

# Путь к логу
BOOTSTRAP_LOG_FILE="$INSTALL_SCRIPT_DIR/logs/bootstrap.log"

# Функция логирования
log_to_file() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [BOOTSTRAP] $*" >> "$BOOTSTRAP_LOG_FILE" 2>/dev/null || true
}

# === Функция проверки интернет соединения ===
check_internet() {
    print_step "Проверка интернет соединения..."
    
    local test_hosts=("8.8.8.8" "1.1.1.1" "github.com")
    local connection_ok=false
    
    for host in "${test_hosts[@]}"; do
        if ping -c 1 -W 5 "$host" >/dev/null 2>&1; then
            print_success "Соединение с $host: OK"
            log_to_file "Internet check: $host OK"
            connection_ok=true
            break
        else
            print_warning "Соединение с $host: FAILED"
            log_to_file "Internet check: $host FAILED"
        fi
    done
    
    if [[ "$connection_ok" != "true" ]]; then
        print_error "Нет интернет соединения"
        print_info "Проверьте:"
        print_info "  • Сетевое подключение"
        print_info "  • DNS настройки"
        print_info "  • Брандмауэр"
        log_to_file "ERROR: No internet connection available"
        return 1
    fi
    
    return 0
}

# === Функция проверки GitHub доступности ===
check_github_access() {
    print_step "Проверка доступности GitHub..."
    
    # Проверяем основной GitHub с детальной диагностикой
    print_info "Тестируем https://github.com..."
    local github_test
    github_test=$(curl -sI --connect-timeout 10 --max-time 30 -w "HTTP_CODE:%{http_code};TIME:%{time_total}" "https://github.com" 2>&1)
    local github_exit_code=$?
    
    print_info "Результат curl github.com: код завершения=$github_exit_code"
    # Логируем только краткую информацию, не полный HTML
    local http_code
    http_code=$(echo "$github_test" | grep -o "HTTP_CODE:[0-9]*" | cut -d: -f2)
    local time_total
    time_total=$(echo "$github_test" | grep -o "TIME:[0-9.]*" | cut -d: -f2)
    log_to_file "GitHub curl test: exit_code=$github_exit_code, http_code=${http_code:-unknown}, time=${time_total:-unknown}"
    
    if [[ $github_exit_code -eq 0 ]]; then
        print_success "GitHub доступен через HTTPS"
        log_to_file "GitHub HTTPS access: OK"
        
        # Дополнительно проверяем конкретный репозиторий
        print_info "Тестируем доступ к репозиторию..."
        local repo_test
        repo_test=$(curl -sI --connect-timeout 5 --max-time 15 -w "HTTP_CODE:%{http_code}" "https://github.com/danil-murashkin/server_script.git" 2>&1)
        local repo_exit_code=$?
        
        print_info "Результат curl репозитория: код завершения=$repo_exit_code"
        local repo_http_code
        repo_http_code=$(echo "$repo_test" | grep -o "HTTP_CODE:[0-9]*" | cut -d: -f2)
        log_to_file "Repository curl test: exit_code=$repo_exit_code, http_code=${repo_http_code:-unknown}"
        
        if [[ $repo_exit_code -eq 0 ]]; then
            print_success "Репозиторий доступен для клонирования"
            log_to_file "Repository clone access: OK"
            return 0
        else
            print_warning "Репозиторий недоступен для клонирования (код: $repo_exit_code)"
            print_info "Пробуем raw доступ..."
            log_to_file "Repository clone access: FAILED with code $repo_exit_code"
        fi
    else
        print_warning "GitHub недоступен через HTTPS (код: $github_exit_code)"
        log_to_file "GitHub HTTPS access: FAILED with code $github_exit_code"
        print_info "Ошибка соединения с GitHub"
    fi
    
    # Проверяем raw доступ в любом случае
    print_info "Тестируем raw.githubusercontent.com..."
    local raw_test
    raw_test=$(curl -sI --connect-timeout 10 --max-time 30 -w "HTTP_CODE:%{http_code}" "https://raw.githubusercontent.com/danil-murashkin/server_script/main/README.md" 2>&1)
    local raw_exit_code=$?
    
    print_info "Результат curl raw GitHub: код завершения=$raw_exit_code"
    local raw_http_code
    raw_http_code=$(echo "$raw_test" | grep -o "HTTP_CODE:[0-9]*" | cut -d: -f2)
    log_to_file "Raw GitHub curl test: exit_code=$raw_exit_code, http_code=${raw_http_code:-unknown}"
    
    if [[ $raw_exit_code -eq 0 ]]; then
        if [[ "$raw_http_code" == "200" ]]; then
            print_success "Raw GitHub доступен - используем альтернативный способ"
            log_to_file "Raw GitHub access: OK (HTTP 200)"
            return 2  # Альтернативный способ
        else
            print_warning "Raw GitHub доступен, но файл не найден (HTTP: ${raw_http_code:-unknown})"
            log_to_file "Raw GitHub access: Available but file not found - HTTP ${raw_http_code:-unknown}"
            return 2  # Попробуем всё же альтернативный способ
        fi
    else
        print_error "Raw GitHub также недоступен (код: $raw_exit_code)"
        log_to_file "Raw GitHub access: FAILED with code $raw_exit_code"
    fi
    
    return 1
}

# === Функция установки через curl (альтернативный способ) ===
download_via_curl() {
    print_step "Альтернативный способ скачивания (через curl)..."
    
    local files=(
        "install.sh"
        "config/main.conf"
        "utils/print.sh"
        "utils/functions.sh" 
        "utils/logging.sh"
    )
    
    mkdir -p "$INSTALL_SCRIPT_DIR"/{config,utils,modules}
    
    for file in "${files[@]}"; do
        local url="$REPO_URL_ALT/$file"
        local dest="$INSTALL_SCRIPT_DIR/$file"
        
        print_info "Скачивание: $file"
        if curl -sSL --connect-timeout 10 --max-time 60 "$url" -o "$dest"; then
            print_success "Скачан: $file"
            log_to_file "Downloaded via curl: $file"
        else
            print_error "Не удалось скачать: $file"
            log_to_file "ERROR: Failed to download via curl: $file"
            return 1
        fi
    done
    
    # Скачиваем модули
    print_info "Скачивание модулей..."
    local modules=(
        "01-prerequisites.sh"
        "02-basic-software.sh"
        "03-user-management.sh"
        "04-certificates.sh"
        "05-hostname.sh"
        "06-firewall.sh"
        "07-dns-server.sh"
        "08-web-server.sh"
        "09-database.sh"
        "10-php-fpm.sh"
        "11-mail-postfix.sh"
        "12-mail-opendkim.sh"
        "13-mail-dovecot.sh"
        "14-webadmin-postfixadmin.sh"
        "15-webmail-roundcube.sh"
        "16-proxy-http-squid.sh"
        "17-proxy-socks-dante.sh"
        "18-vpn-wireguard.sh"
        "19-git-gitea.sh"
        "20-cloud-nextcloud.sh"
        "99-system-check.sh"
    )
    
    for module in "${modules[@]}"; do
        local url="$REPO_URL_ALT/modules/$module"
        local dest="$INSTALL_SCRIPT_DIR/modules/$module"
        
        if curl -sSL --connect-timeout 10 --max-time 60 "$url" -o "$dest" 2>/dev/null; then
            print_info "Модуль скачан: $module"
            log_to_file "Downloaded module: $module"
        else
            print_warning "Не удалось скачать модуль: $module (будет пропущен)"
            log_to_file "WARNING: Failed to download module: $module"
        fi
    done
    
    chmod +x "$INSTALL_SCRIPT"
    return 0
}

# === Проверка прав root ===
if [[ $EUID -ne 0 ]]; then
    print_error "Этот скрипт требует прав root."
    print_info "Запустите: sudo $0"
    exit 1
fi

log_to_file "=== Bootstrap запущен $(date) ==="
log_to_file "Аргументы: $*"
log_to_file "Пользователь: $(whoami), UID: $EUID"

# === Проверка ОС: Debian 11+ ===
print_step "Проверка операционной системы..."

if ! grep -q "Debian" /etc/os-release 2>/dev/null; then
    print_error "Поддерживается только Debian 11+"
    log_to_file "ERROR: Not Debian OS"
    exit 1
fi

VERSION_LINE=$(grep "^VERSION_ID" /etc/os-release)
if [[ -z "$VERSION_LINE" ]]; then
    print_error "Не удалось определить VERSION_ID"
    log_to_file "ERROR: Cannot determine VERSION_ID"
    exit 1
fi

VERSION=$(echo "$VERSION_LINE" | cut -d= -f2 | tr -d '"')
MAIN_VERSION=$(echo "$VERSION" | cut -d. -f1)

if [[ ! "$MAIN_VERSION" =~ ^[0-9]+$ ]] || [[ "$MAIN_VERSION" -lt 11 ]]; then
    print_error "Требуется Debian 11 или новее. Найдено: Debian $VERSION"
    log_to_file "ERROR: Unsupported Debian version: $VERSION"
    exit 1
fi

print_success "ОС: Debian $VERSION"
log_to_file "OS check: Debian $VERSION OK"

# === Проверка свободного места на диске ===
print_step "Проверка свободного места на диске..."

min_space_kb=$((2 * 1024 * 1024))  # 2 ГБ в КБ
free_space=$(df / --output=avail -k | tail -n1 | tr -d ' ')

if [[ "$free_space" -lt "$min_space_kb" ]]; then
    print_error "Недостаточно места: требуется 2 ГБ, доступно: $((free_space / 1024)) МБ"
    log_to_file "ERROR: Not enough disk space: available $((free_space / 1024)) MB"
    exit 1
else
    print_success "Свободно места: $((free_space / 1024)) МБ"
    log_to_file "Disk space check: OK, $((free_space / 1024)) MB available"
fi

# === Проверка и установка зависимостей ===
print_step "Установка зависимостей..."

# Умная обработка процессов apt/dpkg
print_step "Проверка блокирующих процессов apt/dpkg..."

# Функция для проверки и остановки unattended-upgrades в режиме ожидания
handle_unattended_upgrades() {
    local unattended_pids
    unattended_pids=$(pgrep -f "unattended-upgrade" 2>/dev/null || true)
    
    if [[ -n "$unattended_pids" ]]; then
        # Проверяем, есть ли процесс в режиме --wait-for-signal
        for pid in $unattended_pids; do
            local cmdline
            cmdline=$(cat "/proc/$pid/cmdline" 2>/dev/null | tr '\0' ' ' || true)
            
            if [[ "$cmdline" == *"--wait-for-signal"* ]]; then
                print_info "Обнаружен unattended-upgrades в режиме ожидания (PID: $pid)"
                print_step "Автоматическая остановка unattended-upgrades..."
                
                # Останавливаем через systemctl (более чистый способ)
                if systemctl stop unattended-upgrades.service 2>/dev/null; then
                    print_success "unattended-upgrades остановлен через systemctl"
                    log_to_file "Stopped unattended-upgrades.service via systemctl"
                else
                    # Если systemctl не сработал, убиваем процесс
                    if kill -TERM "$pid" 2>/dev/null; then
                        sleep 3
                        if kill -0 "$pid" 2>/dev/null; then
                            kill -KILL "$pid" 2>/dev/null || true
                        fi
                        print_success "unattended-upgrades принудительно остановлен"
                        log_to_file "Forcefully stopped unattended-upgrades PID: $pid"
                    fi
                fi
                return 0
            elif [[ "$cmdline" == *"unattended-upgrade"* ]] && [[ "$cmdline" != *"--wait-for-signal"* ]]; then
                # Активный процесс обновления - нужно ждать
                print_warning "Обнаружен активный процесс unattended-upgrades (PID: $pid)"
                log_to_file "Active unattended-upgrades process detected: $pid"
                return 1
            fi
        done
    fi
    return 0
}

# Проверяем блокировки файлов
check_apt_locks() {
    local lock_files=(
        "/var/lib/dpkg/lock-frontend"
        "/var/lib/dpkg/lock"
        "/var/cache/apt/archives/lock"
        "/var/lib/apt/lists/lock"
    )
    
    for lock_file in "${lock_files[@]}"; do
        if [[ -f "$lock_file" ]] && fuser "$lock_file" >/dev/null 2>&1; then
            local pid
            pid=$(fuser "$lock_file" 2>/dev/null | awk '{print $1}' | head -1)
            if [[ -n "$pid" ]]; then
                local process_name
                process_name=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
                print_warning "Блокировка $lock_file занята процессом: $process_name (PID: $pid)"
                log_to_file "Lock file $lock_file held by $process_name (PID: $pid)"
                return 1
            fi
        fi
    done
    return 0
}

# Сначала обрабатываем unattended-upgrades
if ! handle_unattended_upgrades; then
    print_info "Ожидание завершения активного процесса обновлений..."
fi

# Теперь проверяем другие процессы apt/dpkg
if pgrep -f "apt-get|aptitude|dpkg" >/dev/null || ! check_apt_locks; then
    print_warning "Обнаружены активные процессы apt/dpkg или заблокированы файлы"
    print_info "Ожидание завершения... (до 120 секунд)"
    
    local timeout=120
    local elapsed=0
    
    while (pgrep -f "apt-get|aptitude|dpkg" >/dev/null || ! check_apt_locks) && [[ $elapsed -lt $timeout ]]; do
        sleep 10
        elapsed=$((elapsed + 10))
        printf "."
        
        # Каждые 30 секунд показываем прогресс
        if [[ $((elapsed % 30)) -eq 0 ]]; then
            printf " [%d/%ds]" $elapsed $timeout
        fi
    done
    echo
    
    # Если процессы всё ещё работают после таймаута
    if pgrep -f "apt-get|aptitude|dpkg" >/dev/null || ! check_apt_locks; then
        print_warning "Процессы не завершились за $timeout секунд"
        print_step "Принудительная очистка блокировок..."
        
        # Показываем, какие процессы мешают
        print_info "Активные процессы:"
        pgrep -f "apt-get|aptitude|dpkg" | while read -r pid; do
            local cmd
            cmd=$(ps -p "$pid" -o cmd= 2>/dev/null || echo "unknown")
            print_info "  PID $pid: $cmd"
        done
        
        # Принудительная остановка
        pkill -f "apt-get|aptitude|dpkg" 2>/dev/null || true
        sleep 5
        
        # Очистка блокировок
        rm -f /var/lib/dpkg/lock* 2>/dev/null || true
        rm -f /var/cache/apt/archives/lock 2>/dev/null || true
        rm -f /var/lib/apt/lists/lock 2>/dev/null || true
        
        print_success "Блокировки очищены"
        log_to_file "Forced cleanup of apt locks completed"
    fi
fi

print_success "Процессы apt/dpkg свободны"

# Обновляем список пакетов с диагностикой
print_info "Обновление списка пакетов..."
if apt update -qq 2>/dev/null; then
    print_success "Список пакетов обновлён"
    log_to_file "apt update: OK"
else
    print_warning "Ошибка обновления списка пакетов"
    log_to_file "WARNING: apt update failed"
    
    # Пробуем исправить проблемы
    print_info "Попытка исправления..."
    apt --fix-broken install -y >/dev/null 2>&1 || true
    dpkg --configure -a >/dev/null 2>&1 || true
    apt update -qq >/dev/null 2>&1 || print_warning "Обновление всё ещё не работает"
fi

# Функция для установки пакета с повторными попытками
install_package() {
    local package="$1"
    local max_attempts=3
    local attempt=1
    
    if dpkg -l "$package" 2>/dev/null | grep -q "^ii"; then
        print_success "Пакет $package уже установлен"
        log_to_file "Package $package already installed"
        return 0
    fi
    
    while [[ $attempt -le $max_attempts ]]; do
        print_info "Установка $package (попытка $attempt/$max_attempts)"
        
        if DEBIAN_FRONTEND=noninteractive apt install -y "$package" >/dev/null 2>&1; then
            print_success "Пакет $package установлен"
            log_to_file "Package $package installed on attempt $attempt"
            return 0
        else
            print_warning "Попытка $attempt неудачна для $package"
            log_to_file "Package $package install failed on attempt $attempt"
            
            if [[ $attempt -lt $max_attempts ]]; then
                sleep 2
                apt update -qq >/dev/null 2>&1 || true
            fi
        fi
        
        ((attempt++))
    done
    
    print_error "Не удалось установить пакет: $package"
    log_to_file "ERROR: Failed to install package: $package after $max_attempts attempts"
    return 1
}

# Устанавливаем зависимости
for package in git curl gnupg2 ca-certificates; do
    install_package "$package" || {
        print_error "Критическая ошибка: не удалось установить $package"
        exit 1
    }
done

# === Проверка интернета и GitHub ===
if ! check_internet; then
    exit 1
fi

github_status=0
check_github_access && github_status=$? || github_status=$?

# === Скачивание установщика ===
print_step "Скачивание установщика..."


case $github_status in
    0)
        # Обычное клонирование через git
        print_info "Клонирование через git..."
        log_to_file "Attempting git clone from $REPO_URL"
        
        if timeout 120 git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$INSTALL_SCRIPT_DIR" 2>/dev/null; then
            print_success "Репозиторий клонирован"
            log_to_file "Git clone: SUCCESS"
        else
            print_warning "Git clone не удался, пробуем альтернативный способ..."
            log_to_file "Git clone: FAILED, trying alternative"
            
            if ! download_via_curl; then
                print_error "Все способы скачивания не удались"
                log_to_file "ERROR: All download methods failed"
                exit 1
            fi
        fi
        ;;
    2)
        # Альтернативный способ
        print_info "Используем альтернативный способ скачивания..."
        log_to_file "Using alternative download method"
        if ! download_via_curl; then
            print_error "Альтернативное скачивание не удалось"
            log_to_file "ERROR: Alternative download failed"
            exit 1
        fi
        ;;
    *)
        print_error "GitHub недоступен (статус: $github_status)"
        print_info ""
        print_info "🔍 ДИАГНОСТИКА ПРОБЛЕМ:"
        
        # DNS проверка
        print_info "Проверка DNS..."
        if command -v dig >/dev/null; then
            local dns_result
            dns_result=$(dig +short github.com 2>&1)
            if [[ -n "$dns_result" ]]; then
                print_success "DNS разрешение github.com: $dns_result"
            else
                print_error "DNS разрешение github.com: FAILED"
            fi
        else
            local nslookup_result
            nslookup_result=$(nslookup github.com 2>&1 | grep "Address:" | tail -1)
            if [[ -n "$nslookup_result" ]]; then
                print_success "DNS: $nslookup_result"
            else
                print_error "DNS разрешение: FAILED"
            fi
        fi
        
        # Проверка сертификатов
        print_info "Проверка SSL сертификата..."
        local ssl_check
        ssl_check=$(echo | timeout 10 openssl s_client -connect github.com:443 -servername github.com 2>&1 | grep "Verify return code:")
        if [[ "$ssl_check" == *"0 (ok)"* ]]; then
            print_success "SSL сертификат: OK"
        else
            print_warning "SSL сертификат: $ssl_check"
        fi
        
        # Проверка сетевой связности
        print_info "Проверка сетевой связности с github.com:443..."
        if timeout 10 bash -c "</dev/tcp/github.com/443" 2>/dev/null; then
            print_success "TCP соединение с github.com:443: OK"
        else
            print_error "TCP соединение с github.com:443: FAILED"
        fi
        
        # Проверка прокси
        print_info "Проверка переменных прокси..."
        local proxy_vars=(http_proxy https_proxy HTTP_PROXY HTTPS_PROXY)
        local proxy_found=false
        for var in "${proxy_vars[@]}"; do
            if [[ -n "${!var}" ]]; then
                print_info "  $var=${!var}"
                proxy_found=true
            fi
        done
        if [[ "$proxy_found" == "false" ]]; then
            print_info "  Прокси не настроен"
        fi
        
        print_info ""
        print_info "📋 ВОЗМОЖНЫЕ РЕШЕНИЯ:"
        print_info "  1. Проверьте интернет соединение"
        print_info "  2. Попробуйте другой DNS (8.8.8.8, 1.1.1.1)"
        print_info "  3. Отключите VPN/прокси если используется"
        print_info "  4. Проверьте настройки брандмауэра"
        print_info "  5. Попробуйте с другой сети"
        print_info ""
        
        log_to_file "ERROR: GitHub not accessible, status: $github_status, diagnostics completed"
        exit 1
        ;;
esac

# === Проверка скачанных файлов ===
if [[ ! -f "$INSTALL_SCRIPT" ]]; then
    print_error "Файл install.sh не найден после скачивания"
    log_to_file "ERROR: install.sh not found after download"
    
    print_info "Содержимое $INSTALL_SCRIPT_DIR:"
    ls -la "$INSTALL_SCRIPT_DIR" 2>/dev/null || print_error "Директория $INSTALL_SCRIPT_DIR не существует"
    exit 1
fi

chmod +x "$INSTALL_SCRIPT"
print_success "Установщик готов к запуску"

# === Финальные проверки ===
print_step "Финальные проверки..."

# Проверяем наличие основных файлов
required_files=(
    "$INSTALL_SCRIPT_DIR/utils/print.sh"
    "$INSTALL_SCRIPT_DIR/utils/functions.sh"
    "$INSTALL_SCRIPT_DIR/utils/logging.sh"
    "$INSTALL_SCRIPT_DIR/config/main.conf"
)

for file in "${required_files[@]}"; do
    if [[ ! -f "$file" ]]; then
        print_warning "Отсутствует файл: $file"
        log_to_file "WARNING: Missing file: $file"
    else
        print_info "✓ $(basename "$file")"
    fi
done

# === Условный запуск установки ===
if [[ "$AUTO_INSTALL" == "true" ]]; then
    # === Запуск установки ===
    log_to_file "=== Launching install.sh with args: ${INSTALL_ARGS[*]} ==="
    log_to_file "Working directory: $INSTALL_SCRIPT_DIR"
    log_to_file "Install script: $INSTALL_SCRIPT"

    print_success "🚀 Запуск установки..."
    cd "$INSTALL_SCRIPT_DIR" || {
        print_error "Не удалось перейти в $INSTALL_SCRIPT_DIR"
        exit 1
    }

    # Экспортируем переменные для install.sh
    export FORCE_MODE="${FORCE_MODE:-false}"
    export PROJECT_DIR="$INSTALL_SCRIPT_DIR"

    # Запускаем с обработкой ошибок
    if [[ "$BACKGROUND_MODE" == "true" ]]; then
        nohup bash "$INSTALL_SCRIPT" "${INSTALL_ARGS[@]}" </dev/null >> "$BOOTSTRAP_LOG_FILE" 2>&1 &
        print_success "Установка запущена в фоне (PID: $!)"
        print_info "Следите за логами: tail -f $BOOTSTRAP_LOG_FILE"
        exit 0
    elif ! bash "$INSTALL_SCRIPT" "${INSTALL_ARGS[@]}"; then
        print_error "Установка завершилась с ошибкой"
        log_to_file "ERROR: install.sh exited with error code $?"
        print_info "Логи доступны в: $BOOTSTRAP_LOG_FILE"
        print_info "Рабочая директория сохранена в: $INSTALL_SCRIPT_DIR"
        exit 1
    fi

    print_success "✅ Bootstrap завершён успешно"
    log_to_file "Bootstrap completed successfully"
else
    print_success "📦 Все файлы скачаны в: $INSTALL_SCRIPT_DIR"
    print_info "Для запуска установки выполните:"
    print_info "  cd $INSTALL_SCRIPT_DIR"
    print_info "  bash install.sh [опции]"
    print_info ""
    print_info "Или используйте --install для автозапуска:"
    print_info "  curl -sSL ...bootstrap.sh | bash -s -- --install"
    log_to_file "Bootstrap completed, files downloaded to: $INSTALL_SCRIPT_DIR"
fi