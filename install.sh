#!/bin/bash

export DEBIAN_FRONTEND=noninteractive
export UCF_FORCE_CONFFNEW=1
export UCF_FORCE_CONFFMISS=1
APT_OPTS=(-o Dpkg::Options::="--force-confnew" -o Dpkg::Options::="--force-confmiss" --assume-yes)

LOGFILE="/root/ptero_install.log"
exec > >(tee -a $LOGFILE) 2>&1

# --- PADAM SEMUA CONFIG LAMA DAN GANTI DENGAN VERSI PACKAGE MAINTAINER ---
echo "Padam semua config .dpkg-old, .dpkg-dist, .dpkg-new, .ucf-old sebelum install/upgrade..."
find /etc -type f \( -name "*.dpkg-old" -o -name "*.dpkg-dist" -o -name "*.dpkg-new" -o -name "*.ucf-old" \) -exec rm -f {} \;

echo "Ganti semua config modified dengan versi package maintainer (jika ada)..."
find /etc -type f -name "*.dpkg-dist" | while read conf; do
  base_conf="${conf%.dpkg-dist}"
  echo "Ganti $base_conf dengan versi package maintainer"
  cp -f "$conf" "$base_conf"
  rm -f "$conf"
done

retry_cmd() {
  local n=0
  local max=3
  local delay=5
  until [ $n -ge $max ]; do
    "$@" && break
    n=$((n+1))
    echo "Command failed. Attempt $n/$max. Retrying in $delay seconds..."
    sleep $delay
    auto_fix "$@"
  done
  if [ $n -eq $max ]; then
    echo "Command failed after $max attempts, check logs."
    # Tunjuk error apt jika ada
    apt_errors=$(cat /root/ptero_install.log | grep -i 'error\|failed\|broken')
    if [ ! -z "$apt_errors" ]; then
      echo "APT errors detected:"
      echo "$apt_errors"
      echo "Try running: sudo apt --fix-broken install -y && sudo dpkg --configure -a && sudo apt update"
      # Auto fix again for last time (tambahan auto-fix pada error akhir)
      echo "Mencuba auto-fix akhir untuk masalah APT/dpkg..."
      sudo apt --fix-broken install -y || true
      sudo dpkg --configure -a || true
      sudo apt update --allow-releaseinfo-change || true
      sudo apt upgrade -y "${APT_OPTS[@]}" || true
      sudo apt autoremove -y || true
      sudo apt clean || true
      sudo apt -y "${APT_OPTS[@]}" upgrade || true
    fi
    exit 1
  fi
}

auto_fix() {
  local cmd="$*"
  echo "Trying auto-fix for: $cmd"
  if [[ $cmd == *apt* ]]; then
    sudo apt --fix-broken install -y || true
    sudo dpkg --configure -a || true
    sudo apt update --allow-releaseinfo-change || true
    sudo apt upgrade -y "${APT_OPTS[@]}" || true
    sudo apt autoremove -y || true
    sudo apt clean || true
    sudo apt -y "${APT_OPTS[@]}" upgrade || true
  fi
  if [[ $cmd == *mysql* ]]; then
    sudo systemctl restart mysql || true
  fi
  if [[ $cmd == *composer* ]]; then
    sudo apt install -y composer "${APT_OPTS[@]}" || true
  fi
  if [[ $cmd == *nginx* ]]; then
    sudo systemctl restart nginx || true
  fi
  # Auto-fix tambahan sekiranya dpkg lock atau broken
  if sudo fuser /var/lib/dpkg/lock >/dev/null 2>&1; then
    echo "Ada lock dpkg, cuba buang lock..."
    sudo rm -f /var/lib/dpkg/lock
  fi
  if sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
    echo "Ada lock apt lists, cuba buang lock..."
    sudo rm -f /var/lib/apt/lists/lock
  fi
  if sudo fuser /var/cache/apt/archives/lock >/dev/null 2>&1; then
    echo "Ada lock apt archives, cuba buang lock..."
    sudo rm -f /var/cache/apt/archives/lock
  fi
  # Cuba recreate dpkg status file jika corrupt
  if [ ! -s /var/lib/dpkg/status ]; then
    echo "File dpkg status tiada atau kosong, cuba recreate..."
    sudo cp /var/lib/dpkg/status-old /var/lib/dpkg/status || true
  fi
}

echo "==== [1] Update & Install Dependencies ===="
retry_cmd sudo apt update "${APT_OPTS[@]}"
retry_cmd sudo apt upgrade -y "${APT_OPTS[@]}"
retry_cmd sudo apt install -y curl wget git nginx mysql-server redis-server nodejs npm unzip tar composer "${APT_OPTS[@]}"

echo "==== [2] Setup MariaDB/MySQL Database ===="
retry_cmd sudo systemctl start mysql
retry_cmd sudo mysql -e "CREATE DATABASE IF NOT EXISTS panel;"
retry_cmd sudo mysql -e "CREATE USER IF NOT EXISTS 'ptero'@'localhost' IDENTIFIED BY 'pteropass';"
retry_cmd sudo mysql -e "GRANT ALL PRIVILEGES ON panel.* TO 'ptero'@'localhost';"
retry_cmd sudo mysql -e "FLUSH PRIVILEGES;"

echo "==== [3] Install Pterodactyl Panel ===="
retry_cmd sudo mkdir -p /var/www/pterodactyl
retry_cmd sudo chown -R $(whoami):$(whoami) /var/www/pterodactyl
retry_cmd git clone https://github.com/pterodactyl/panel.git /var/www/pterodactyl
cd /var/www/pterodactyl
retry_cmd git checkout $(git describe --tags $(git rev-list --tags --max-count=1))
retry_cmd cp .env.example .env
retry_cmd composer install --no-dev --optimize-autoloader
retry_cmd php artisan key:generate --force
retry_cmd php artisan migrate --force || auto_fix "php artisan migrate --force"
retry_cmd php artisan p:environment:setup --auto
retry_cmd php artisan p:environment:database --auto
retry_cmd php artisan p:environment:mail --auto
# Buat user admin auto (email: admin@local, user: admin, password: ptero123)
retry_cmd php artisan p:user:make --email=admin@local --username=admin --name="Admin" --password="ptero123" --admin=1 || retry_cmd php artisan p:user:make --auto
retry_cmd sudo chown -R www-data:www-data /var/www/pterodactyl/*

echo "==== [4] Install Wings Daemon ===="
retry_cmd sudo mkdir -p /srv/daemon
retry_cmd sudo chown -R $(whoami):$(whoami) /srv/daemon
retry_cmd curl -L https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64 -o /srv/daemon/wings
retry_cmd chmod +x /srv/daemon/wings
cat <<EOF | sudo tee /etc/systemd/system/wings.service
[Unit]
Description=Pterodactyl Wings Daemon
After=network.target

[Service]
User=root
WorkingDirectory=/srv/daemon
ExecStart=/srv/daemon/wings
Restart=always
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
EOF
retry_cmd sudo systemctl daemon-reload
retry_cmd sudo systemctl enable wings
retry_cmd sudo systemctl start wings

echo "==== [5] Setup Nginx ===="
cat <<'NGINX' | sudo tee /etc/nginx/sites-available/pterodactyl
server {
    listen 80;
    server_name _;
    root /var/www/pterodactyl/public;
    index index.php index.html;
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location ~ \.php$ {
        fastcgi_pass unix:/var/run/php/php8.1-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
NGINX
retry_cmd sudo ln -sf /etc/nginx/sites-available/pterodactyl /etc/nginx/sites-enabled/pterodactyl
retry_cmd sudo systemctl reload nginx

echo "==== [6] Download Egg for Bot Hosting (Wing) ===="
sudo mkdir -p /var/lib/pterodactyl/eggs
retry_cmd sudo wget -O /var/lib/pterodactyl/eggs/bot-wing.json https://raw.githubusercontent.com/parkervcp/eggs/master/bots/wing/egg-wing.json

echo "==== [7] FINISHED ===="
echo "============================================="
echo "Pterodactyl Panel + Wings + Bot Wing Egg installed!"
echo "Panel Link: http://$(hostname -I | awk '{print $1}')"
echo "Admin Login:"
echo "  Username: admin"
echo "  Email   : admin@local"
echo "  Password: ptero123"
echo "Daemon: Wings status: $(sudo systemctl is-active wings)"
echo "Log: $LOGFILE"
echo "============================================="
