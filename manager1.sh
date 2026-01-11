#!/bin/bash
#########################################################################
# HOSTING MANAGER v1.1
# Intelligent Domain & Service Management System
# Author: netqcomtr
# Date: 2026-01-11
#########################################################################

set -euo pipefail

#=======================================================================
# COLORS & FORMATTING
#=======================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

#=======================================================================
# CONFIGURATION
#=======================================================================
HOSTING_ROOT="/opt/hosting"
DOMAINS_PATH="$HOSTING_ROOT/domains"
SCRIPTS_PATH="$HOSTING_ROOT/scripts"
LOG_FILE="$HOSTING_ROOT/hosting.log"
PORT_RANGE_START=8000
PORT_RANGE_END=9000
DB_PASS_LENGTH=15

#=======================================================================
# UTILITY FUNCTIONS
#=======================================================================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" | tee -a "$LOG_FILE"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*" | tee -a "$LOG_FILE"
}

print_header() {
    echo -e "\n${BOLD}${CYAN}===================================================${NC}"
    echo -e "${BOLD}${CYAN} $1${NC}"
    echo -e "${BOLD}${CYAN}===================================================${NC}\n"
}

menu_prompt() {
    echo -ne "${BOLD}${BLUE}> ${NC}"
}

generate_strong_password() {
    local length=${1:-$DB_PASS_LENGTH}
    tr -dc 'A-Za-z0-9!@#$%^&*' < /dev/urandom | head -c "$length"
}

generate_username() {
    local domain=$1
    echo "user_$(echo "$domain" | cut -d. -f1 | tr -d '-')_$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' ')"
}

# Daha güvenilir port kontrolü: ss varsa kullan, yoksa netstat; ayrıca domain metadata'larında kontrol et
is_port_available() {
    local port=$1

    # Check listening sockets
    if command -v ss >/dev/null 2>&1; then
        # ss output list addresses in column 5 typically
        if ss -tuln 2>/dev/null | awk '{print $5}' | grep -E -q "[:.]${port}(\$|[:/ ])"; then
            return 1
        fi
    else
        if command -v netstat >/dev/null 2>&1; then
            if netstat -tuln 2>/dev/null | grep -E -q "[:.]${port}(\$|[:/ ])"; then
                return 1
            fi
        fi
    fi

    # Check domain metadata files for already reserved ports
    if [ -d "$DOMAINS_PATH" ]; then
        if grep -R -q "\"port\": ${port}" "$DOMAINS_PATH" 2>/dev/null; then
            return 1
        fi
    fi

    return 0
}

find_available_port() {
    for port in $(seq "$PORT_RANGE_START" "$PORT_RANGE_END"); do
        if is_port_available "$port"; then
            echo "$port"
            return 0
        fi
    done
    log_error "Boş port bulunamadı!"
    return 1
}

validate_domain() {
    local domain=$1
    if [[ $domain =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*\.?$ ]]; then
        return 0
    else
        return 1
    fi
}

#=======================================================================
# İLK KURULUM
#=======================================================================
init_system() {
    print_header "Hosting Manager - İlk Kurulum"
    
    if [ -d "$HOSTING_ROOT" ]; then
        log_warning "$HOSTING_ROOT zaten mevcut"
        return
    fi
    
    log_info "Dizin yapısı oluşturuluyor..."
    mkdir -p "$DOMAINS_PATH" "$SCRIPTS_PATH"
    touch "$LOG_FILE"
    
    if ! docker network ls | grep -q "hosting-network"; then
        log_info "Docker network oluşturuluyor: hosting-network"
        docker network create hosting-network 2>/dev/null || true
    fi
    
    log_success "Sistem başarıyla kuruldu!"
    log_info "Root: $HOSTING_ROOT"
}

#=======================================================================
# DOMAIN IŞLEMLERI
#=======================================================================
domain_exists() {
    local domain=$1
    [ -d "$DOMAINS_PATH/$domain" ]
}

create_domain_structure() {
    local domain=$1
    local domain_path="$DOMAINS_PATH/$domain"
    
    log_info "Domain dizin yapısı oluşturuluyor: $domain"
    mkdir -p "$domain_path"/{volumes,backups,logs,cron}
    touch "$domain_path/.env"
    
    log_success "Domain yapısı oluşturuldu: $domain_path"
}

create_domain_metadata() {
    local domain=$1
    local domain_path="$DOMAINS_PATH/$domain"
    local metadata_file="$domain_path/domain.json"
    
    cat > "$metadata_file" <<EOF
{
  "domain": "$domain",
  "services": {},
  "credentials": {},
  "created_at": "$(date '+%Y-%m-%d')",
  "updated_at": "$(date '+%Y-%m-%d')",
  "backups": {
    "enabled": true,
    "schedule": "daily",
    "retention_days": 30
  },
  "last_backup": null,
  "status": "active"
}
EOF
}

create_docker_compose_template() {
    local domain=$1
    local domain_path="$DOMAINS_PATH/$domain"
    local compose_file="$domain_path/docker-compose.yml"
    
    cat > "$compose_file" <<EOF
version: '3.8'

services:

networks:
  hosting-network:
    external: true

volumes:
EOF
}

add_domain() {
    print_header "Yeni Domain Ekle"
    
    menu_prompt
    read -p "Domain adı (örn: example.com): " domain
    
    if ! validate_domain "$domain"; then
        log_error "Geçersiz domain formatı!"
        return 1
    fi
    
    if domain_exists "$domain"; then
        log_error "Bu domain zaten var: $domain"
        return 1
    fi
    
    log_info "Domain ekleniyor: $domain"
    
    create_domain_structure "$domain"
    create_domain_metadata "$domain"
    create_docker_compose_template "$domain"
    
    add_standard_services "$domain"
    
    menu_prompt
    read -p "Harici bir servis eklemek ister misiniz? (y/n): " add_external
    if [[ "$add_external" =~ ^[Yy]$ ]]; then
        add_external_service "$domain"
    fi
    
    setup_domain_cron "$domain"
    start_domain "$domain"
    
    log_success "Domain başarıyla eklendi: $domain"
    show_installation_summary "$domain"
}

#=======================================================================
# STANDART SERVISLER
#=======================================================================
add_standard_services() {
    local domain=$1
    local domain_path="$DOMAINS_PATH/$domain"
    
    print_header "Standart Servisler"
    echo -e "${CYAN}Aşağıdaki hizmetleri etkinleştirmek ister misiniz?${NC}\n"
    
    local services_count=0
    
    menu_prompt
    read -p "Apache (PHP-FPM destekli) ekle? (y/n): " add_apache
    if [[ "$add_apache" =~ ^[Yy]$ ]]; then
        local apache_port
        apache_port=$(find_available_port)
        add_service_apache "$domain" "$apache_port"
        ((services_count++))
    fi
    
    menu_prompt
    read -p "MySQL/MariaDB ekle? (y/n): " add_mysql
    if [[ "$add_mysql" =~ ^[Yy]$ ]]; then
        local mysql_port
        mysql_port=$(find_available_port)
        add_service_mysql "$domain" "$mysql_port"
        ((services_count++))
    fi
    
    menu_prompt
    read -p "FreeRadius ekle? (y/n): " add_freeradius
    if [[ "$add_freeradius" =~ ^[Yy]$ ]]; then
        local radius_port
        radius_port=$(find_available_port)
        add_service_freeradius "$domain" "$radius_port"
        ((services_count++))
    fi
    
    menu_prompt
    read -p "phpMyAdmin ekle? (y/n): " add_phpmyadmin
    if [[ "$add_phpmyadmin" =~ ^[Yy]$ ]]; then
        local phpmyadmin_port
        phpmyadmin_port=$(find_available_port)
        add_service_phpmyadmin "$domain" "$phpmyadmin_port"
        ((services_count++))
    fi
    
    if [ $services_count -eq 0 ]; then
        log_warning "Hiçbir standart servis eklenmedi"
    fi
}

add_service_apache() {
    local domain=$1
    local port=$2
    local domain_path="$DOMAINS_PATH/$domain"
    local compose_file="$domain_path/docker-compose.yml"
    
    log_info "Apache servisi ekleniyor (Port: $port)"
    
    cat >> "$compose_file" <<EOF
  apache-$domain:
    image: php:8.2-apache
    container_name: apache-$domain
    ports:
      - "$port:80"
    volumes:
      - $domain_path/volumes/apache:/var/www/html
      - $domain_path/logs/apache:/var/log/apache2
    environment:
      - DOMAIN=$domain
    networks:
      - hosting-network
    restart: always
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost/"]
      interval: 30s
      timeout: 10s
      retries: 3

EOF
    
    echo "APACHE_PORT=$port" >> "$domain_path/.env"
    
    jq ".services.apache = {\"port\": $port, \"image\": \"php:8.2-apache\"}" "$domain_path/domain.json" > "$domain_path/domain.json.tmp"
    mv "$domain_path/domain.json.tmp" "$domain_path/domain.json"
    
    mkdir -p "$domain_path/volumes/apache"
    echo "<?php phpinfo(); ?>" > "$domain_path/volumes/apache/index.php"
    
    log_success "Apache eklendi (Port: $port)"
}

add_service_mysql() {
    local domain=$1
    local port=$2
    local domain_path="$DOMAINS_PATH/$domain"
    local compose_file="$domain_path/docker-compose.yml"
    
    log_info "MySQL servisi ekleniyor (Port: $port)"
    
    local db_user
    db_user=$(generate_username "$domain")
    local db_pass
    db_pass=$(generate_strong_password $DB_PASS_LENGTH)
    local db_root_pass
    db_root_pass=$(generate_strong_password $DB_PASS_LENGTH)
    local db_name="db_$(echo "$domain" | cut -d. -f1 | tr -d '-')"
    
    cat >> "$compose_file" <<EOF
  mysql-$domain:
    image: mysql:8.0
    container_name: mysql-$domain
    ports:
      - "$port:3306"
    volumes:
      - $domain_path/volumes/mysql:/var/lib/mysql
      - $domain_path/logs/mysql:/var/log/mysql
    environment:
      - MYSQL_ROOT_PASSWORD=$db_root_pass
      - MYSQL_DATABASE=$db_name
      - MYSQL_USER=$db_user
      - MYSQL_PASSWORD=$db_pass
    networks:
      - hosting-network
    restart: always
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-uroot", "-p$db_root_pass"]
      interval: 30s
      timeout: 10s
      retries: 3

EOF
    
    cat >> "$domain_path/.env" <<EOF
MYSQL_PORT=$port
MYSQL_ROOT_PASSWORD=$db_root_pass
MYSQL_DATABASE=$db_name
MYSQL_USER=$db_user
MYSQL_PASSWORD=$db_pass
EOF
    
    jq ".services.mysql = {\"port\": $port, \"image\": \"mysql:8.0\"} | .credentials.db_user = \"$db_user\" | .credentials.db_pass = \"$db_pass\" | .credentials.db_root_pass = \"$db_root_pass\" | .credentials.db_name = \"$db_name\"" "$domain_path/domain.json" > "$domain_path/domain.json.tmp"
    mv "$domain_path/domain.json.tmp" "$domain_path/domain.json"
    
    mkdir -p "$domain_path/volumes/mysql"
    
    cat > "$domain_path/mysql_info.txt" <<EOF
╔═══════════════════════════════════════════════════════════════╗
║ MySQL Veritabanı Bilgileri - $domain
╠═══════════════════════════════════════════════════════════════╣
║ Host (Container'dan): mysql-$domain
║ Host (Dış): localhost
║ Port: $port
║ Root Password: $db_root_pass
║ Database: $db_name
║ Username: $db_user
║ Password: $db_pass
╚═══════════════════════════════════════════════════════════════╝
EOF
    
    log_success "MySQL eklendi (Port: $port, User: $db_user)"
}

add_service_freeradius() {
    local domain=$1
    local port=$2
    local domain_path="$DOMAINS_PATH/$domain"
    local compose_file="$domain_path/docker-compose.yml"
    
    log_info "FreeRadius servisi ekleniyor (Port: $port)"
    
    cat >> "$compose_file" <<EOF
  freeradius-$domain:
    image: freeradius/freeradius-server:latest
    container_name: freeradius-$domain
    ports:
      - "$port:1812/udp"
      - "$((port+1)):1813/udp"
    volumes:
      - $domain_path/volumes/freeradius:/etc/raddb
      - $domain_path/logs/freeradius:/var/log/freeradius
    networks:
      - hosting-network
    restart: always
    environment:
      - FREERADIUS_DEBUG=0

EOF
    
    echo "FREERADIUS_PORT=$port" >> "$domain_path/.env"
    
    jq ".services.freeradius = {\"port\": $port, \"image\": \"freeradius/freeradius-server:latest\"}" "$domain_path/domain.json" > "$domain_path/domain.json.tmp"
    mv "$domain_path/domain.json.tmp" "$domain_path/domain.json"
    
    mkdir -p "$domain_path/volumes/freeradius"
    
    log_success "FreeRadius eklendi (Port: $port)"
}

add_service_phpmyadmin() {
    local domain=$1
    local port=$2
    local domain_path="$DOMAINS_PATH/$domain"
    local compose_file="$domain_path/docker-compose.yml"
    
    log_info "phpMyAdmin servisi ekleniyor (Port: $port)"
    
    cat >> "$compose_file" <<EOF
  phpmyadmin-$domain:
    image: phpmyadmin:latest
    container_name: phpmyadmin-$domain
    ports:
      - "$port:80"
    environment:
      - PMA_HOST=mysql-$domain
      - PMA_PORT=3306
    depends_on:
      - mysql-$domain
    networks:
      - hosting-network
    restart: always

EOF
    
    echo "PHPMYADMIN_PORT=$port" >> "$domain_path/.env"
    
    jq ".services.phpmyadmin = {\"port\": $port, \"image\": \"phpmyadmin:latest\"}" "$domain_path/domain.json" > "$domain_path/domain.json.tmp"
    mv "$domain_path/domain.json.tmp" "$domain_path/domain.json"
    
    log_success "phpMyAdmin eklendi (Port: $port)"
}

#=======================================================================
# HARİCİ/ÖZEL SERVIS MODÜLÜ
#=======================================================================
add_external_service() {
    local domain=$1
    local domain_path="$DOMAINS_PATH/$domain"
    
    print_header "Harici Servis Ekleme"
    
    menu_prompt
    read -p "Servis adı (ör: redis, custom-app): " service_name
    menu_prompt
    read -p "Docker Hub imaj yolu (ör: redis:latest): " service_image
    menu_prompt
    read -p "Servis portu (boş bırakın otomatik atama için): " service_port
    
    if [ -z "$service_port" ]; then
        service_port=$(find_available_port)
    fi
    
    log_info "Harici servis ekleniyor: $service_name"
    
    local compose_file="$domain_path/docker-compose.yml"
    
    cat >> "$compose_file" <<EOF
  $service_name-$domain:
    image: $service_image
    container_name: $service_name-$domain
    ports:
      - "$service_port:$service_port"
    volumes:
      - $domain_path/volumes/$service_name:/data
    networks:
      - hosting-network
    restart: always

EOF
    
    # normalize env var name to uppercase and replace non-alnum with _
    local env_name
    env_name=$(echo "$service_name" | tr '[:lower:]-' '[:upper:]_')
    echo "${env_name}_PORT=$service_port" >> "$domain_path/.env"
    
    jq ".services.$service_name = {\"port\": $service_port, \"image\": \"$service_image\"}" "$domain_path/domain.json" > "$domain_path/domain.json.tmp"
    mv "$domain_path/domain.json.tmp" "$domain_path/domain.json"
    
    mkdir -p "$domain_path/volumes/$service_name"
    
    log_success "Harici servis eklendi: $service_name (Port: $service_port)"
}

#=======================================================================
# DOCKER IŞLEMLERI
#=======================================================================
start_domain() {
    local domain=$1
    local domain_path="$DOMAINS_PATH/$domain"
    
    if [ ! -f "$domain_path/docker-compose.yml" ]; then
        log_error "Docker Compose dosyası bulunamadı: $domain"
        return 1
    fi
    
    log_info "Domain başlatılıyor: $domain"
    cd "$domain_path"
    
    if docker compose up -d 2>/dev/null || docker-compose up -d; then
        log_success "Domain başarıyla başlatıldı: $domain"
        jq ".updated_at = \"$(date '+%Y-%m-%d')\" | .status = \"active\"" "$domain_path/domain.json" > "$domain_path/domain.json.tmp"
        mv "$domain_path/domain.json.tmp" "$domain_path/domain.json"
        return 0
    else
        log_error "Domain başlatılırken hata oluştu: $domain"
        return 1
    fi
}

stop_domain() {
    local domain=$1
    local domain_path="$DOMAINS_PATH/$domain"
    
    if [ ! -f "$domain_path/docker-compose.yml" ]; then
        log_error "Docker Compose dosyası bulunamadı: $domain"
        return 1
    fi
    
    log_info "Domain durduruluyor: $domain"
    cd "$domain_path"
    docker compose down 2>/dev/null || docker-compose down
    
    jq ".status = \"stopped\"" "$domain_path/domain.json" > "$domain_path/domain.json.tmp"
    mv "$domain_path/domain.json.tmp" "$domain_path/domain.json"
    
    log_success "Domain durduruldu: $domain"
}

restart_domain() {
    local domain=$1
    stop_domain "$domain"
    sleep 2
    start_domain "$domain"
}

update_domain_services() {
    local domain=$1
    local domain_path="$DOMAINS_PATH/$domain"
    
    log_info "Domain servisleri güncelleniyor: $domain"
    cd "$domain_path"
    docker compose pull 2>/dev/null || docker-compose pull
    docker compose up -d 2>/dev/null || docker-compose up -d
    
    log_success "Domain servisleri güncellendi: $domain"
}

#=======================================================================
# YEDEKLEME (BACKUP) IŞLEMLERI
#=======================================================================
backup_domain() {
    local domain=$1
    local domain_path="$DOMAINS_PATH/$domain"
    local backup_dir="$domain_path/backups"
    
    if ! domain_exists "$domain"; then
        log_error "Domain bulunamadı: $domain"
        return 1
    fi
    
    local backup_name="backup_$(date '+%Y%m%d_%H%M%S')"
    local backup_path="$backup_dir/$backup_name"
    
    log_info "Yedekleme başlatılıyor: $domain -> $backup_name"
    mkdir -p "$backup_path"
    
    if [ -d "$domain_path/volumes" ]; then
        log_info "Volumes yedekleniyor..."
        cp -r "$domain_path/volumes" "$backup_path/"
    fi
    
    [ -f "$domain_path/docker-compose.yml" ] && cp "$domain_path/docker-compose.yml" "$backup_path/"
    [ -f "$domain_path/.env" ] && cp "$domain_path/.env" "$backup_path/"
    [ -f "$domain_path/domain.json" ] && cp "$domain_path/domain.json" "$backup_path/"
    
    if docker ps --format '{{.Names}}' | grep -q "mysql-$domain"; then
        log_info "MySQL veritabanı dump'ı alınıyor..."
        local db_root_pass
        db_root_pass=$(grep "MYSQL_ROOT_PASSWORD" "$domain_path/.env" | cut -d= -f2)
        docker exec mysql-$domain mysqldump -uroot -p"$db_root_pass" --all-databases > "$backup_path/database.sql" 2>/dev/null || true
    fi
    
    cat > "$backup_path/backup_info.txt" <<EOF
╔═══════════════════════════════════════════════════════════════╗
║ YEDEKLEME BİLGİLERİ
╠═══════════════════════════════════════════════════════════════╣
║ Domain: $domain
║ Yedek Adı: $backup_name
║ Yedek Tarihi: $(date '+%Y-%m-%d %H:%M:%S')
║ Yedek Yolu: $backup_path
║ Dosya Sayısı: $(find "$backup_path" -type f | wc -l)
║ Toplam Boyut: $(du -sh "$backup_path" | cut -f1)
╚═══════════════════════════════════════════════════════════════╝
EOF
    
    jq ".last_backup = \"$backup_name\"" "$domain_path/domain.json" > "$domain_path/domain.json.tmp"
    mv "$domain_path/domain.json.tmp" "$domain_path/domain.json"
    
    log_success "Yedekleme tamamlandı: $backup_name"
    log_info "Yedek boyutu: $(du -sh "$backup_path" | cut -f1)"
}

restore_domain_backup() {
    local domain=$1
    local domain_path="$DOMAINS_PATH/$domain"
    local backup_dir="$domain_path/backups"
    
    if [ ! -d "$backup_dir" ]; then
        log_error "Yedek dizini bulunamadı: $domain"
        return 1
    fi
    
    print_header "Yedek Geri Yükleme - $domain"
    echo -e "${CYAN}Mevcut yedekler:${NC}\n"
    
    local backup_list=($(ls -1d "$backup_dir"/backup_* 2>/dev/null | xargs -n1 basename))
    
    if [ ${#backup_list[@]} -eq 0 ]; then
        log_error "Kullanılabilir yedek bulunamadı"
        return 1
    fi
    
    for i in "${!backup_list[@]}"; do
        echo "$((i+1))) ${backup_list[$i]}"
    done
    
    menu_prompt
    read -p "Geri yüklemek istediğiniz yedek numarasını girin: " backup_choice
    
    local backup_name="${backup_list[$((backup_choice-1))]}"
    local backup_path="$backup_dir/$backup_name"
    
    if [ ! -d "$backup_path" ]; then
        log_error "Geçersiz yedek seçimi"
        return 1
    fi
    
    log_warning "Domain durduruluyor..."
    stop_domain "$domain"
    sleep 2
    
    log_info "Veriler geri yükleniyor..."
    
    if [ -d "$backup_path/volumes" ]; then
        log_info "Volumes geri yükleniyor..."
        rm -rf "$domain_path/volumes"
        cp -r "$backup_path/volumes" "$domain_path/"
    fi
    
    [ -f "$backup_path/.env" ] && cp "$backup_path/.env" "$domain_path/.env"
    [ -f "$backup_path/docker-compose.yml" ] && cp "$backup_path/docker-compose.yml" "$domain_path/"
    
    log_success "Veriler geri yüklendi"
    
    log_info "Domain yeniden başlatılıyor..."
    start_domain "$domain"
    
    if [ -f "$backup_path/database.sql" ]; then
        log_info "Veritabanı geri yükleniyor (30 saniye bekleniyor)..."
        sleep 30
        local db_root_pass
        db_root_pass=$(grep "MYSQL_ROOT_PASSWORD" "$domain_path/.env" | cut -d= -f2)
        docker exec -i mysql-$domain mysql -uroot -p"$db_root_pass" < "$backup_path/database.sql" 2>/dev/null || log_warning "Veritabanı geri yüklenemedi"
    fi
    
    log_success "Geri yükleme tamamlandı: $backup_name"
}

cleanup_old_backups() {
    local domain=$1
    local domain_path="$DOMAINS_PATH/$domain"
    local backup_dir="$domain_path/backups"
    local retention_days=30
    
    if [ ! -d "$backup_dir" ]; then
        return
    fi
    
    log_info "Eski yedekler temizleniyor: $domain (>$retention_days gün)"
    find "$backup_dir" -maxdepth 1 -type d -name "backup_*" -mtime +$retention_days -exec rm -rf {} \; 2>/dev/null || true
    log_success "Eski yedekler temizlendi"
}

#=======================================================================
# CRON / ZAMANLANMıŞ GÖREVLER
#=======================================================================
setup_domain_cron() {
    local domain=$1
    local domain_path="$DOMAINS_PATH/$domain"
    local cron_dir="$domain_path/cron"
    
    log_info "Cron görevleri kurulması: $domain"
    
    cat > "$cron_dir/daily_backup.sh" <<EOF
#!/bin/bash
DOMAIN="$domain"
SCRIPT_PATH="\$0"
cd "\$(dirname "\$SCRIPT_PATH")/../.."
bash hosting.sh backup "\$DOMAIN"
EOF
    chmod +x "$cron_dir/daily_backup.sh"
    
    cat > "$cron_dir/cleanup.sh" <<EOF
#!/bin/bash
DOMAIN="$domain"
SCRIPT_PATH="\$0"
cd "\$(dirname "\$SCRIPT_PATH")/../.."
bash hosting.sh cleanup "\$DOMAIN"
EOF
    chmod +x "$cron_dir/cleanup.sh"
    
    log_success "Cron görevleri kuruldu"
}

enable_automatic_backups() {
    local domain=$1
    
    print_header "Otomatik Yedekleme Ayarları"
    
    echo -e "${CYAN}Yedekleme sıklığını seçin:${NC}\n"
    echo "1) Günlük (02:00)"
    echo "2) Haftalık (Pazartesi 02:00)"
    echo "3) Aylık (1. gün 02:00)"
    echo "4) Devre dışı bırak"
    
    menu_prompt
    read -p "Seçim: " schedule_choice
    
    local cron_time=""
    case $schedule_choice in
        1) cron_time="0 2 * * *" ;;
        2) cron_time="0 2 * * 1" ;;
        3) cron_time="0 2 1 * *" ;;
        4)
            log_info "Otomatik yedekleme devre dışı"
            crontab -l 2>/dev/null | grep -v "/opt/hosting/domains/$domain/cron/daily_backup.sh" | crontab -
            return
            ;;
        *)
            log_error "Geçersiz seçim"
            return
            ;;
    esac
    
    local cron_entry="$cron_time /opt/hosting/domains/$domain/cron/daily_backup.sh >> /opt/hosting/hosting.log 2>&1"
    (crontab -l 2>/dev/null | grep -v "/opt/hosting/domains/$domain/cron/daily_backup.sh"; echo "$cron_entry") | crontab -
    
    log_success "Otomatik yedekleme etkinleştirildi"
}

#=======================================================================
# DOMAIN LİSTELEME
#=======================================================================
list_domains() {
    print_header "Kurulu Domainler"
    
    if [ ! -d "$DOMAINS_PATH" ] || [ -z "$(ls -A "$DOMAINS_PATH" 2>/dev/null)" ]; then
        log_warning "Hiçbir domain bulunamadı"
        return
    fi
    
    printf "%-30s | %-15s | %-15s | %-15s | %-20s\n" "Domain" "Status" "Servisler" "Disk" "Son Yedek"
    printf "%-30s-+-%-15s-+-%-15s-+-%-15s-+-%-20s\n" "$(printf '=%.0s' {1..30})" "$(printf '=%.0s' {1..15})" "$(printf '=%.0s' {1..15})" "$(printf '=%.0s' {1..15})" "$(printf '=%.0s' {1..20})"
    
    for domain_dir in "$DOMAINS_PATH"/*; do
        if [ ! -d "$domain_dir" ]; then
            continue
        fi
        
        local domain
        domain=$(basename "$domain_dir")
        local metadata_file="$domain_dir/domain.json"
        
        local status="Unknown"
        if [ -f "$domain_dir/docker-compose.yml" ]; then
            cd "$domain_dir" || true
            if docker compose ps 2>/dev/null | grep -q "Up" || docker-compose ps 2>/dev/null | grep -q "Up"; then
                status="${GREEN}Running${NC}"
            else
                status="${RED}Stopped${NC}"
            fi
        fi
        
        local service_count=0
        if [ -f "$metadata_file" ]; then
            service_count=$(jq '.services | length' "$metadata_file" 2>/dev/null || echo 0)
        fi
        
        local disk_usage
        disk_usage=$(du -sh "$domain_dir" 2>/dev/null | cut -f1 || echo "N/A")
        
        local last_backup="None"
        if [ -f "$metadata_file" ]; then
            last_backup=$(jq -r '.last_backup // "None"' "$metadata_file" 2>/dev/null)
        fi
        
        printf "%-30s | %-15b | %-15s | %-15s | %-20s\n" "$domain" "$status" "$service_count servis" "$disk_usage" "$last_backup"
    done
}

#=======================================================================
# DOMAIN SİLME
#=======================================================================
delete_domain() {
    local domain=$1
    local domain_path="$DOMAINS_PATH/$domain"
    
    if ! domain_exists "$domain"; then
        log_error "Domain bulunamadı: $domain"
        return 1
    fi
    
    print_header "Domain Silme - $domain"
    log_warning "Bu işlem geri alınamaz!"
    
    menu_prompt
    read -p "Silmeden önce yedek almak ister misiniz? (y/n): " backup_before_delete
    if [[ "$backup_before_delete" =~ ^[Yy]$ ]]; then
        backup_domain "$domain"
    fi
    
    menu_prompt
    read -p "Emin misiniz? Doğrulamak için '$domain' yazın: " confirm
    if [ "$confirm" != "$domain" ]; then
        log_warning "Silme işlemi iptal edildi"
        return
    fi
    
    log_info "Domain siliniyor: $domain"
    
    stop_domain "$domain"
    sleep 2
    
    cd "$domain_path" || true
    docker compose down -v 2>/dev/null || docker-compose down -v 2>/dev/null || true
    
    rm -rf "$domain_path"
    
    (crontab -l 2>/dev/null | grep -v "/opt/hosting/domains/$domain/") | crontab - 2>/dev/null || true
    
    log_success "Domain başarıyla silindi: $domain"
}

#=======================================================================
# SİSTEM & GÜVENLİK MENÜSÜ
#=======================================================================
system_security_menu() {
    print_header "Sistem & Güvenlik"
    
    while true; do
        echo -e "\n${CYAN}Sistem Yönetimi:${NC}\n"
        echo "1) SSH Root Login Aç/Kapat"
        echo "2) Root Şifresi Değiştir"
        echo "3) SSH Port Değiştir"
        echo "4) Docker İstatistikleri Göster"
        echo "5) Fail2Ban Durumu"
        echo "0) Geri"
        
        menu_prompt
        read -p "Seçim: " security_choice
        
        case $security_choice in
            1) toggle_ssh_root_login ;;
            2) change_root_password ;;
            3) change_ssh_port ;;
            4) show_docker_stats ;;
            5) show_fail2ban_status ;;
            0) return ;;
            *) log_error "Geçersiz seçim" ;;
        esac
    done
}

toggle_ssh_root_login() {
    local ssh_config="/etc/ssh/sshd_config"
    local current_status
    current_status=$(grep "^PermitRootLogin" "$ssh_config" 2>/dev/null | awk '{print $2}' || echo "not set")
    
    print_header "SSH Root Login Kontrolü"
    echo "Mevcut durum: $current_status"
    
    menu_prompt
    read -p "Root login'i aktifleştir? (y/n): " enable_root
    
    if [[ "$enable_root" =~ ^[Yy]$ ]]; then
        sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' "$ssh_config"
        systemctl restart sshd || service ssh restart
        log_success "Root login etkinleştirildi"
    else
        sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' "$ssh_config"
        systemctl restart sshd || service ssh restart
        log_success "Root login devre dışı bırakıldı"
    fi
}

change_root_password() {
    print_header "Root Şifresi Değiştirme"
    if passwd root; then
        log_success "Root şifresi başarıyla değiştirildi"
    else
        log_error "Root şifresi değiştirilemedi"
    fi
}

change_ssh_port() {
    local ssh_config="/etc/ssh/sshd_config"
    print_header "SSH Port Değiştirme"
    
    local current_port
    current_port=$(grep "^Port" "$ssh_config" 2>/dev/null | awk '{print $2}' || echo "22")
    echo "Mevcut SSH Port: $current_port"
    
    menu_prompt
    read -p "Yeni SSH Port'u girin: " new_port
    
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        log_error "Geçersiz port numarası"
        return
    fi
    
    sed -i "s/^#*Port.*/Port $new_port/" "$ssh_config"
    
    if systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null; then
        log_success "SSH Port değiştirildi: $new_port"
        log_warning "Yeni bağlantılarda port $new_port kullanın!"
    else
        log_error "SSH Port değiştirilemedi"
    fi
}

show_docker_stats() {
    print_header "Docker İstatistikleri"
    echo -e "${CYAN}Çalışan Container'lar:${NC}\n"
    docker stats --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}"
}

show_fail2ban_status() {
    print_header "Fail2Ban Durumu"
    
    if ! command -v fail2ban-client &> /dev/null; then
        log_warning "Fail2Ban yüklü değil"
        menu_prompt
        read -p "Fail2Ban yüklemek ister misiniz? (y/n): " install_fail2ban
        if [[ "$install_fail2ban" =~ ^[Yy]$ ]]; then
            log_info "Fail2Ban yükleniyor..."
            apt-get update && apt-get install -y fail2ban
            systemctl enable fail2ban
            systemctl start fail2ban
            log_success "Fail2Ban yüklendi"
        fi
        return
    fi
    
    echo -e "${CYAN}Fail2Ban Servisi:${NC}\n"
    fail2ban-client status
    
    echo -e "\n${CYAN}Engellenen IP'ler:${NC}\n"
    fail2ban-client status sshd 2>/dev/null || echo "SSH jail yapılandırılmamış"
}

#=======================================================================
# ÖZETİ GÖSTER (KURULUM SONU)
#=======================================================================
show_installation_summary() {
    local domain=$1
    local domain_path="$DOMAINS_PATH/$domain"
    local metadata_file="$domain_path/domain.json"
    
    if [ ! -f "$metadata_file" ]; then
        log_error "Metadata dosyası bulunamadı"
        return
    fi
    
    clear
    cat <<'SUMMARY'
╔═══════════════════════════════════════════════════════════════════╗
║                                                                   ║
║       🎉 HOSTING KURULUMU BAŞARIYLA TAMAMLANDI 🎉                ║
║                                                                   ║
╚═══════════════════════════════════════════════════════════════════╝
SUMMARY
    
    echo -e "${BOLD}${CYAN}DOMAIN BİLGİLERİ:${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "%-25s | %s\n" "Domain Adı" "$(jq -r '.domain' "$metadata_file")"
    printf "%-25s | %s\n" "Oluşturulma Tarihi" "$(jq -r '.created_at' "$metadata_file")"
    printf "%-25s | %s\n" "Status" "$(jq -r '.status' "$metadata_file")"
    echo ""
    
    echo -e "${BOLD}${CYAN}KURULU SERVİSLER:${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    local services
    services=$(jq -r '.services | keys[]' "$metadata_file" 2>/dev/null || true)
    
    if [ -z "$services" ]; then
        echo "Hiçbir servis kurulmadı"
    else
        while IFS= read -r service; do
            [ -z "$service" ] && continue
            local port
            port=$(jq -r ".services.\"$service\".port" "$metadata_file")
            local image
            image=$(jq -r ".services.\"$service\".image" "$metadata_file")
            printf "%-15s | Port: %-6s | Image: %s\n" "$(echo "$service" | tr '[:lower:]' '[:upper:]')" "$port" "$image"
        done <<< "$services"
    fi
    echo ""
    
    local db_user
    db_user=$(jq -r '.credentials.db_user // "N/A"' "$metadata_file" 2>/dev/null)
    if [ "$db_user" != "N/A" ]; then
        echo -e "${BOLD}${CYAN}VERİTABANI BİLGİLERİ:${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        printf "%-25s | %s\n" "Veritabanı Adı" "$(jq -r '.credentials.db_name // "N/A"' "$metadata_file")"
        printf "%-25s | %s\n" "Kullanıcı Adı" "$db_user"
        printf "%-25s | %s\n" "Şifre" "$(jq -r '.credentials.db_pass // "N/A"' "$metadata_file")"
        printf "%-25s | %s\n" "Root Şifresi" "$(jq -r '.credentials.db_root_pass // "N/A"' "$metadata_file")"
        printf "%-25s | %s\n" "Host (Container)" "mysql-$domain"
        printf "%-25s | %s\n" "Host (Dış)" "localhost"
        printf "%-25s | %s\n" "Port" "$(jq -r '.services.mysql.port // "N/A"' "$metadata_file")"
        echo ""
    fi
    
    echo -e "${BOLD}${CYAN}YEDEKLEME AYARLARI:${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "%-25s | %s\n" "Otomatik Yedekleme" "$(jq -r '.backups.enabled' "$metadata_file")"
    printf "%-25s | %s\n" "Yedekleme Sıklığı" "$(jq -r '.backups.schedule' "$metadata_file")"
    printf "%-25s | %s gün\n" "Bekletme Süresi" "$(jq -r '.backups.retention_days' "$metadata_file")"
    printf "%-25s | %s\n" "Son Yedekleme" "$(jq -r '.last_backup // "Henüz yedeklenmedi"' "$metadata_file")"
    echo ""
    
    echo -e "${BOLD}${CYAN}DOSYA YOLLARI:${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "%-25s | %s\n" "Domain Dizini" "$domain_path"
    printf "%-25s | %s\n" "Docker Compose" "$domain_path/docker-compose.yml"
    printf "%-25s | %s\n" "Environment" "$domain_path/.env"
    printf "%-25s | %s\n" "Volumes" "$domain_path/volumes"
    printf "%-25s | %s\n" "Yedekler" "$domain_path/backups"
    echo ""
    
    echo -e "${BOLD}${CYAN}NGINX PROXY MANAGER AYARLARI:${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Servisler için Nginx Proxy Manager ayarları:"
    echo ""
    
    while IFS= read -r service; do
        [ -z "$service" ] && continue
        local port
        port=$(jq -r ".services.\"$service\".port" "$metadata_file")
        echo " • $service:"
        echo "   - Forward Host: 172.17.0.1"
        echo "   - Forward Port: $port"
        echo "   - Forward Scheme: http"
        echo "   - SSL önerilir: Let's Encrypt"
        echo ""
    done <<< "$services"
    
    echo -e "${BOLD}${CYAN}YARDIMCI KOMUTLAR:${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    cat <<COMMANDS
# Domain durumunu kontrol et
cd $domain_path && docker compose ps

# Tüm logları görüntüle
cd $domain_path && docker compose logs -f

# Manuel yedekleme al
bash /opt/hosting/hosting.sh backup $domain

# Servisleri yeniden başlat
cd $domain_path && docker compose restart
COMMANDS
    
    echo ""
    echo -e "${BOLD}${CYAN}İLETİŞİM:${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Log dosyası: $LOG_FILE"
    echo ""
    
    cat <<'FOOTER'
╔═══════════════════════════════════════════════════════════════════╗
║                                                                   ║
║            🚀 Kurulum başarıyla tamamlandı!                      ║
║                                                                   ║
╚═══════════════════════════════════════════════════════════════════╝
FOOTER
}

#=======================================================================
# ANA MENÜ
#=======================================================================
# ---- Değiştirilmiş show_main_menu() ----
show_main_menu() {
    print_header "HOSTING MANAGER v1.1"
    
    echo -e "${CYAN}Domain Yönetimi:${NC}\n"
    echo "1) Yeni Domain Ekle"
    echo "2) Domain Listele"
    echo "3) Domain Yönet"
    echo "4) Domain Sil"
    echo "5) Yedekleme İşlemleri"
    
    echo -e "\n${CYAN}Sistem Yönetimi:${NC}\n"
    echo "6) Sistem & Güvenlik"
    echo "7) Docker İstatistikleri"
    echo "8) Logları Görüntüle"
    
    echo -e "\n${CYAN}Genel:${NC}\n"
    echo "0) Çık"
    
    menu_prompt
    read -p "Seçim: " main_choice

    # echo ile seçimi stdout'a yazıp fonksiyonun exit kodunu 0 olarak bırakıyoruz
    echo "$main_choice"
}
# ---- Sonu ----

# ---- Değiştirilmiş ana döngü kısmı (main) ----
main() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Bu script root yetkisiyle çalışmalıdır!"
        exit 1
    fi
    
    if [ ! -d "$HOSTING_ROOT" ]; then
        init_system
    fi
    
    while true; do
        # show_main_menu artık seçimi echo ediyor, burada çıktıyı yakalıyoruz
        main_choice=$(show_main_menu)
        
        case $main_choice in
            1) add_domain ;;
            2) list_domains ;;
            3)
                print_header "Domain Seç"
                local domains=($(ls -1d "$DOMAINS_PATH"/* 2>/dev/null | xargs -n1 basename || true))
                if [ ${#domains[@]} -eq 0 ]; then
                    log_warning "Hiçbir domain bulunamadı"
                else
                    for i in "${!domains[@]}"; do
                        echo "$((i+1))) ${domains[$i]}"
                    done
                    menu_prompt
                    read -p "Domain numarasını girin: " domain_choice
                    local selected_domain="${domains[$((domain_choice-1))]}"
                    if [ ! -z "$selected_domain" ]; then
                        manage_domain_menu "$selected_domain"
                    fi
                fi
                ;;
            4)
                print_header "Domain Sil"
                local domains=($(ls -1d "$DOMAINS_PATH"/* 2>/dev/null | xargs -n1 basename || true))
                if [ ${#domains[@]} -eq 0 ]; then
                    log_warning "Hiçbir domain bulunamadı"
                else
                    for i in "${!domains[@]}"; do
                        echo "$((i+1))) ${domains[$i]}"
                    done
                    menu_prompt
                    read -p "Domain numarasını girin: " domain_choice
                    local selected_domain="${domains[$((domain_choice-1))]}"
                    if [ ! -z "$selected_domain" ]; then
                        delete_domain "$selected_domain"
                    fi
                fi
                ;;
            5) backup_menu ;;
            6) system_security_menu ;;
            7)
                print_header "Docker İstatistikleri"
                docker stats --no-stream
                ;;
            8)
                print_header "Loglar"
                tail -100 "$LOG_FILE"
                ;;
            0)
                log_info "Programdan çıkılıyor..."
                exit 0
                ;;
            *) log_error "Geçersiz seçim" ;;
        esac
        
        read -p "Devam etmek için Enter'a basın..."
    done
}
# ---- Sonu ----

#=======================================================================
# ANA PROGRAM
#=======================================================================
main() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Bu script root yetkisiyle çalışmalıdır!"
        exit 1
    fi
    
    if [ ! -d "$HOSTING_ROOT" ]; then
        init_system
    fi
    
    while true; do
        show_main_menu
        main_choice=$?
        
        case $main_choice in
            1) add_domain ;;
            2) list_domains ;;
            3)
                print_header "Domain Seç"
                local domains=($(ls -1d "$DOMAINS_PATH"/* 2>/dev/null | xargs -n1 basename || true))
                if [ ${#domains[@]} -eq 0 ]; then
                    log_warning "Hiçbir domain bulunamadı"
                else
                    for i in "${!domains[@]}"; do
                        echo "$((i+1))) ${domains[$i]}"
                    done
                    menu_prompt
                    read -p "Domain numarasını girin: " domain_choice
                    local selected_domain="${domains[$((domain_choice-1))]}"
                    if [ ! -z "$selected_domain" ]; then
                        manage_domain_menu "$selected_domain"
                    fi
                fi
                ;;
            4)
                print_header "Domain Sil"
                local domains=($(ls -1d "$DOMAINS_PATH"/* 2>/dev/null | xargs -n1 basename || true))
                if [ ${#domains[@]} -eq 0 ]; then
                    log_warning "Hiçbir domain bulunamadı"
                else
                    for i in "${!domains[@]}"; do
                        echo "$((i+1))) ${domains[$i]}"
                    done
                    menu_prompt
                    read -p "Domain numarasını girin: " domain_choice
                    local selected_domain="${domains[$((domain_choice-1))]}"
                    if [ ! -z "$selected_domain" ]; then
                        delete_domain "$selected_domain"
                    fi
                fi
                ;;
            5) backup_menu ;;
            6) system_security_menu ;;
            7)
                print_header "Docker İstatistikleri"
                docker stats --no-stream
                ;;
            8)
                print_header "Loglar"
                tail -100 "$LOG_FILE"
                ;;
            0)
                log_info "Programdan çıkılıyor..."
                exit 0
                ;;
            *) log_error "Geçersiz seçim" ;;
        esac
        
        read -p "Devam etmek için Enter'a basın..."
    done
}

#=======================================================================
# KOMUT SATIRI PARAMETRELERI
#=======================================================================
case "${1:-}" in
    backup)
        if [ -z "$2" ]; then
            log_error "Domain adı gerekli: $0 backup DOMAIN"
            exit 1
        fi
        backup_domain "$2"
        ;;
    restore)
        if [ -z "$2" ]; then
            log_error "Domain adı gerekli: $0 restore DOMAIN"
            exit 1
        fi
        restore_domain_backup "$2"
        ;;
    start)
        if [ -z "$2" ]; then
            log_error "Domain adı gerekli: $0 start DOMAIN"
            exit 1
        fi
        start_domain "$2"
        ;;
    stop)
        if [ -z "$2" ]; then
            log_error "Domain adı gerekli: $0 stop DOMAIN"
            exit 1
        fi
        stop_domain "$2"
        ;;
    restart)
        if [ -z "$2" ]; then
            log_error "Domain adı gerekli: $0 restart DOMAIN"
            exit 1
        fi
        restart_domain "$2"
        ;;
    list)
        list_domains
        ;;
    delete)
        if [ -z "$2" ]; then
            log_error "Domain adı gerekli: $0 delete DOMAIN"
            exit 1
        fi
        delete_domain "$2"
        ;;
    cleanup)
        if [ -z "$2" ]; then
            log_error "Domain adı gerekli: $0 cleanup DOMAIN"
            exit 1
        fi
        cleanup_old_backups "$2"
        ;;
    *)
        if [ "$EUID" -ne 0 ]; then
            log_error "Bu script root yetkisiyle çalışmalıdır!"
            exit 1
        fi
        main
        ;;
esac
