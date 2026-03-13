.PHONY: install start stop restart status logs build clean backup db-shell cms-shell reset-cache help

# Default target
help:
	@echo "Chronos Hotel — Available Commands"
	@echo ""
	@echo "  make install       Full automated setup (first time)"
	@echo "  make start         Start all services"
	@echo "  make stop          Stop all services"
	@echo "  make restart       Restart all services"
	@echo "  make status        Show container status"
	@echo "  make logs          Follow all container logs"
	@echo "  make logs-SVC      Follow logs for one service (e.g., make logs-arcturus)"
	@echo ""
	@echo "  make build         Rebuild all containers"
	@echo "  make build-SVC     Rebuild one service (e.g., make build-nitro)"
	@echo "  make reset-cache   Clear CMS/Laravel caches"
	@echo ""
	@echo "  make db-shell      Open MySQL shell"
	@echo "  make cms-shell     Open CMS (bash) shell"
	@echo "  make backup        Create manual database backup"
	@echo ""
	@echo "  make clean         Stop containers and remove database data"
	@echo ""

# ─── Installation ───
install:
	@./install.sh

# ─── Lifecycle ───
start:
	docker compose up -d

stop:
	docker compose down

restart:
	docker compose restart

status:
	docker compose ps

# ─── Logs ───
logs:
	docker compose logs -f --tail 100

logs-%:
	docker compose logs -f --tail 100 $*

# ─── Building ───
build:
	docker compose build
	docker compose up -d

build-%:
	docker compose build $*
	docker compose up -d $*

# ─── Database ───
db-shell:
	docker compose exec db mysql -u arcturus_user -parcturus_pw arcturus

backup:
	docker compose exec backup backup-now

# ─── CMS ───
cms-shell:
	docker compose exec cms bash

reset-cache:
	docker compose exec cms php artisan cache:clear
	docker compose exec cms php artisan config:clear
	docker compose exec cms php artisan view:clear
	@echo "Caches cleared"

# ─── Cleanup ───
clean:
	@echo "WARNING: This will stop all containers and delete database data."
	@echo "Press Ctrl+C to cancel, or wait 5 seconds to continue..."
	@sleep 5
	docker compose down -v
	rm -rf db/data
	@echo "Cleaned. Run 'make install' to start fresh."
