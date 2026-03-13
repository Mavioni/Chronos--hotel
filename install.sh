#!/usr/bin/env bash
set -euo pipefail

# Chronos Hotel — Automated Installer
# Installs and configures a complete Habbo Hotel private server

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ─── Colors ───
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }

# ─── Pre-flight checks ───
preflight() {
    info "Running pre-flight checks..."

    if ! command -v docker &>/dev/null; then
        err "Docker is not installed. Install it from https://www.docker.com/get-started/"
        exit 1
    fi

    if ! docker compose version &>/dev/null; then
        err "Docker Compose (v2) is not available. Update Docker Desktop."
        exit 1
    fi

    if ! docker info &>/dev/null 2>&1; then
        err "Docker daemon is not running. Start Docker Desktop first."
        exit 1
    fi

    ok "Docker and Docker Compose are available"
}

# ─── Step 1: Generate config files from examples ───
generate_configs() {
    info "Generating configuration files..."

    local generated=0

    # Copy all example- prefixed files
    find . -maxdepth 2 -type f -name 'example-*' | while read -r src; do
        dst="${src/example-/}"
        if [ ! -f "$dst" ]; then
            cp "$src" "$dst"
            ok "Created $(basename "$dst")"
            generated=$((generated + 1))
        else
            warn "$(basename "$dst") already exists, skipping"
        fi
    done

    ok "Configuration files ready"
}

# ─── Step 2: Download assets ───
download_assets() {
    info "Downloading game assets (this may take a while)..."

    if [ -d "assets/swf/.git" ]; then
        warn "assets/swf already exists, skipping clone"
    else
        info "Cloning SWF asset pack..."
        git clone --depth 1 https://git.mc8051.de/nitro/arcturus-morningstar-default-swf-pack.git assets/swf/
        ok "SWF assets downloaded"
    fi

    if [ -d "assets/assets/.git" ] || [ -d "assets/assets/bundled" ]; then
        warn "assets/assets already exists, skipping clone"
    else
        info "Cloning default assets..."
        git clone --depth 1 https://git.mc8051.de/nitro/default-assets.git assets/assets/
        ok "Default assets downloaded"
    fi

    if [ -f "room.nitro.zip" ]; then
        info "Extracting room assets..."
        mkdir -p assets/assets/bundled/generic
        unzip -o room.nitro.zip -d assets/assets/bundled/generic
        ok "Room assets extracted"
    fi
}

# ─── Step 3: Start database and wait for it ───
start_database() {
    info "Starting database..."
    docker compose up db -d

    info "Waiting for database to be ready..."
    local retries=30
    while ! docker compose exec -T db mysqladmin ping -u root -parcturus_root_pw --silent 2>/dev/null; do
        retries=$((retries - 1))
        if [ $retries -le 0 ]; then
            err "Database failed to start within 60 seconds"
            docker compose logs db
            exit 1
        fi
        sleep 2
    done
    ok "Database is ready"
}

# ─── Step 4: Initialize database schema ───
init_database() {
    info "Initializing database schema..."

    local DB_USER DB_PASS DB_NAME
    DB_USER=$(grep -oP '^MYSQL_USER=\K.*' .env 2>/dev/null || echo "arcturus_user")
    DB_PASS=$(grep -oP '^MYSQL_PASSWORD=\K.*' .env 2>/dev/null || echo "arcturus_pw")
    DB_NAME=$(grep -oP '^MYSQL_DATABASE=\K.*' .env 2>/dev/null || echo "arcturus")

    # Check if tables already exist
    local table_count
    table_count=$(docker compose exec -T db mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" \
        -sNe "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NAME';" 2>/dev/null || echo "0")

    if [ "$table_count" -gt 10 ]; then
        warn "Database already has $table_count tables, skipping schema init"
        return 0
    fi

    # Load base schema
    if [ -f "arcturus/arcturus_3.0.0-stable_base_database--compact.sql" ]; then
        info "Loading base database schema..."
        docker compose exec -T db mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" \
            < arcturus/arcturus_3.0.0-stable_base_database--compact.sql
        ok "Base schema loaded"
    fi

    # Apply SQL updates in order
    local sql_files=(
        "sqlupdates/3_0_0-to-3_5_0.sql"
        "sqlupdates/3_5_0-to-4_0_0.sql"
        "sqlupdates/4_0_0_pets_EN.sql"
        "sqlupdates/4_0_0_permissions.sql"
    )

    for sql_file in "${sql_files[@]}"; do
        if [ -f "$sql_file" ]; then
            info "Applying $(basename "$sql_file")..."
            docker compose exec -T db mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" < "$sql_file" 2>/dev/null || true
        fi
    done

    # Load permission groups
    if [ -f "arcturus/perms_groups.sql" ]; then
        info "Loading permission groups..."
        docker compose exec -T db mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" \
            < arcturus/perms_groups.sql 2>/dev/null || true
    fi

    # Apply emulator settings
    if [ -f "sqlupdates/step7_emulator_settings.sql" ]; then
        info "Applying emulator settings..."
        docker compose exec -T db mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" \
            < sqlupdates/step7_emulator_settings.sql 2>/dev/null || true
    fi

    ok "Database initialized"
}

# ─── Step 5: Create admin user ───
create_admin() {
    local DB_USER DB_PASS DB_NAME
    DB_USER=$(grep -oP '^MYSQL_USER=\K.*' .env 2>/dev/null || echo "arcturus_user")
    DB_PASS=$(grep -oP '^MYSQL_PASSWORD=\K.*' .env 2>/dev/null || echo "arcturus_pw")
    DB_NAME=$(grep -oP '^MYSQL_DATABASE=\K.*' .env 2>/dev/null || echo "arcturus")

    # Check if admin already exists
    local admin_exists
    admin_exists=$(docker compose exec -T db mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" \
        -sNe "SELECT COUNT(*) FROM users WHERE username='admin';" 2>/dev/null || echo "0")

    if [ "$admin_exists" -gt 0 ]; then
        warn "Admin user already exists, skipping"
        return 0
    fi

    info "Creating admin user..."
    docker compose exec -T db mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "
        INSERT INTO users (username, password, mail, account_created, \`rank\`, credits, pixels, points)
        VALUES ('admin', 'admin', 'admin@localhost.com', UNIX_TIMESTAMP(), 7, 10000, 10000, 10000);
    " 2>/dev/null || true
    ok "Admin user created (username: admin, password: admin)"
}

# ─── Step 6: Build and start asset server ───
start_assets() {
    info "Starting asset server..."
    docker compose up assets -d
    ok "Asset server started on port 8080"
}

# ─── Step 7: Build and start game emulator ───
start_emulator() {
    info "Building and starting Arcturus emulator (this takes a few minutes)..."
    docker compose up arcturus --build -d
    ok "Arcturus emulator started"
}

# ─── Step 8: Build and start Nitro client ───
start_nitro() {
    info "Building and starting Nitro client (this takes a few minutes)..."
    docker compose up nitro --build -d
    ok "Nitro client started on port 3000"
}

# ─── Step 9: Build and start CMS ───
start_cms() {
    info "Building and starting AtomCMS (this takes a few minutes)..."
    docker compose up cms --build -d

    info "Waiting for CMS to be ready..."
    sleep 10

    # Generate APP_KEY if placeholder exists
    if grep -q "YOUR_KEY_HERE\|VcFHbHg" .cms.env 2>/dev/null; then
        info "Generating Laravel APP_KEY..."
        local app_key
        app_key=$(docker compose exec -T cms php artisan key:generate --show 2>/dev/null || true)
        if [ -n "$app_key" ]; then
            # Replace the APP_KEY line in .cms.env
            sed -i "s|^APP_KEY=.*|APP_KEY=$app_key|" .cms.env
            ok "APP_KEY generated and saved"

            # Restart CMS to pick up new key
            docker compose restart cms
            sleep 5
        fi
    fi

    # Run migrations
    info "Running CMS database migrations..."
    docker compose exec -T cms php artisan migrate --seed --force 2>/dev/null || true
    ok "CMS migrations complete"
}

# ─── Step 10: Configure website settings ───
configure_website() {
    local DB_USER DB_PASS DB_NAME
    DB_USER=$(grep -oP '^MYSQL_USER=\K.*' .env 2>/dev/null || echo "arcturus_user")
    DB_PASS=$(grep -oP '^MYSQL_PASSWORD=\K.*' .env 2>/dev/null || echo "arcturus_pw")
    DB_NAME=$(grep -oP '^MYSQL_DATABASE=\K.*' .env 2>/dev/null || echo "arcturus")

    info "Configuring website settings..."
    docker compose exec -T db mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "
        UPDATE website_settings SET \`value\` = 'http://127.0.0.1:8080/api/imager/?figure=' WHERE \`key\` = 'avatar_imager';
        UPDATE website_settings SET \`value\` = 'http://127.0.0.1:8080/swf/c_images/album1584' WHERE \`key\` = 'badges_path';
        UPDATE website_settings SET \`value\` = 'http://127.0.0.1:8080/usercontent/badgeparts/generated' WHERE \`key\` = 'group_badge_path';
        UPDATE website_settings SET \`value\` = 'http://127.0.0.1:8080/swf/dcr/hof_furni' WHERE \`key\` = 'furniture_icons_path';
        UPDATE website_settings SET \`value\` = '/housekeeping' WHERE \`key\` = 'housekeeping_url';
        UPDATE website_settings SET \`value\` = 'arcturus' WHERE \`key\` = 'rcon_ip';
        UPDATE website_settings SET \`value\` = '3001' WHERE \`key\` = 'rcon_port';
        UPDATE website_settings SET \`value\` = 'http://127.0.0.1:3000' WHERE \`key\` = 'nitro_path';
        UPDATE website_settings SET \`value\` = '4' WHERE \`key\` = 'min_staff_rank';
        UPDATE website_settings SET \`value\` = '5' WHERE \`key\` = 'min_maintenance_login_rank';
        UPDATE website_settings SET \`value\` = '6' WHERE \`key\` = 'min_housekeeping_rank';
        UPDATE website_settings SET \`value\` = '0' WHERE \`key\` = 'cloudflare_turnstile_enabled';
    " 2>/dev/null || true
    ok "Website settings configured"
}

# ─── Step 11: Fix admin password hash ───
fix_admin_password() {
    info "Setting admin password hash..."
    local hash
    hash=$(docker compose exec -T cms php -r "echo password_hash('admin', PASSWORD_BCRYPT);" 2>/dev/null || true)

    if [ -n "$hash" ]; then
        local DB_USER DB_PASS DB_NAME
        DB_USER=$(grep -oP '^MYSQL_USER=\K.*' .env 2>/dev/null || echo "arcturus_user")
        DB_PASS=$(grep -oP '^MYSQL_PASSWORD=\K.*' .env 2>/dev/null || echo "arcturus_pw")
        DB_NAME=$(grep -oP '^MYSQL_DATABASE=\K.*' .env 2>/dev/null || echo "arcturus")

        docker compose exec -T db mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "
            UPDATE users SET password = '$hash' WHERE username = 'admin';
        " 2>/dev/null || true
        ok "Admin password hash set"
    else
        warn "Could not generate password hash (CMS may not be ready yet)"
    fi
}

# ─── Step 12: Clear caches ───
clear_caches() {
    info "Clearing Laravel caches..."
    docker compose exec -T cms php artisan cache:clear 2>/dev/null || true
    docker compose exec -T cms php artisan config:clear 2>/dev/null || true
    docker compose exec -T cms php artisan view:clear 2>/dev/null || true
    ok "Caches cleared"
}

# ─── Step 13: Show status ───
show_status() {
    echo ""
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}   Chronos Hotel — Installation Complete ${NC}"
    echo -e "${GREEN}=========================================${NC}"
    echo ""
    docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"
    echo ""
    echo -e "${CYAN}Access your hotel:${NC}"
    echo "  Website & Login:   http://localhost:8081"
    echo "  Enter Hotel:       http://localhost:8081/game/nitro"
    echo "  Admin Panel:       http://localhost:8081/housekeeping"
    echo "  Asset Server:      http://127.0.0.1:8080"
    echo ""
    echo -e "${CYAN}Default credentials:${NC}"
    echo "  Username: admin"
    echo "  Password: admin"
    echo ""

    # Show installation key if available
    local DB_USER DB_PASS DB_NAME
    DB_USER=$(grep -oP '^MYSQL_USER=\K.*' .env 2>/dev/null || echo "arcturus_user")
    DB_PASS=$(grep -oP '^MYSQL_PASSWORD=\K.*' .env 2>/dev/null || echo "arcturus_pw")
    DB_NAME=$(grep -oP '^MYSQL_DATABASE=\K.*' .env 2>/dev/null || echo "arcturus")

    local install_key
    install_key=$(docker compose exec -T db mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" \
        -sNe "SELECT installation_key FROM website_installation LIMIT 1;" 2>/dev/null || true)

    if [ -n "$install_key" ]; then
        echo -e "${YELLOW}CMS Installation Key:${NC} $install_key"
        echo "  (Use this on first login at http://localhost:8081)"
        echo ""
    fi

    echo -e "${CYAN}Useful commands:${NC}"
    echo "  make status        — Show container status"
    echo "  make logs          — Follow all logs"
    echo "  make stop          — Stop all services"
    echo "  make start         — Start all services"
    echo "  make restart       — Restart all services"
    echo ""
}

# ─── Main ───
main() {
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     Chronos Hotel — Installer         ║${NC}"
    echo -e "${CYAN}║     Habbo Private Server Setup         ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════╝${NC}"
    echo ""

    preflight
    generate_configs
    download_assets
    start_database
    init_database
    create_admin
    start_assets
    start_emulator
    start_nitro
    start_cms
    configure_website
    fix_admin_password
    clear_caches
    show_status
}

# Allow running individual steps
if [ "${1:-}" = "--step" ] && [ -n "${2:-}" ]; then
    preflight
    case "$2" in
        configs)    generate_configs ;;
        assets)     download_assets ;;
        database)   start_database && init_database && create_admin ;;
        build)      start_assets && start_emulator && start_nitro && start_cms ;;
        configure)  configure_website && fix_admin_password && clear_caches ;;
        status)     show_status ;;
        *)          err "Unknown step: $2. Use: configs, assets, database, build, configure, status" ;;
    esac
else
    main
fi
