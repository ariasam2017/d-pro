#!/usr/bin/env bash
# =============================================================================
# dotinschool — Linux installer/management script (x-ui/Sanaei-panel style)
#
# Install:
#   bash <(curl -Ls https://raw.githubusercontent.com/ariasam2017/d-pro/main/install.sh)
#
# After install, the "dotinschool" management command is available:
#   dotinschool            interactive management menu
#   dotinschool install    install / reinstall
#   dotinschool update     update to the latest version from GitHub
#   dotinschool admin      show/change admin panel address, credentials, and subdomain
#   dotinschool cert       issue/renew an SSL certificate for a domain
#   dotinschool start|stop|restart|status
#   dotinschool enable|disable   enable/disable auto-start on boot
#   dotinschool uninstall
# =============================================================================
set -euo pipefail

REPO_URL="${DOTINSCHOOL_REPO_URL:-git@github.com:ariasam2017/dtnschool.git}"
BRANCH="${DOTINSCHOOL_BRANCH:-main}"

INSTALL_DIR="/opt/dotinschool"
CONFIG_DIR="/etc/dotinschool"
ENV_FILE="${CONFIG_DIR}/dotinschool.env"
SSL_DIR="${CONFIG_DIR}/ssl"
SERVICE_NAME="dotinschool"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
CLI_PATH="/usr/local/bin/dotinschool"
NODE_MAJOR="22"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info(){ echo -e "${CYAN}[i]${NC} $*"; }
ok(){ echo -e "${GREEN}[✓]${NC} $*"; }
warn(){ echo -e "${YELLOW}[!]${NC} $*"; }
err(){ echo -e "${RED}[x]${NC} $*" >&2; }
die(){ err "$*"; exit 1; }

require_root(){
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "This script must be run as root (sudo bash install.sh)."
}

detect_pkg_manager(){
  if command -v apt-get >/dev/null 2>&1; then echo "apt";
  elif command -v dnf >/dev/null 2>&1; then echo "dnf";
  elif command -v yum >/dev/null 2>&1; then echo "yum";
  else die "Your Linux distribution is not supported (apt/dnf/yum only)."; fi
}

install_prereqs(){
  local pm; pm=$(detect_pkg_manager)
  info "Installing prerequisites (curl, git, tar, openssl, ssh)..."
  case "$pm" in
    apt) apt-get update -y >/dev/null; apt-get install -y curl git tar openssl openssh-client ca-certificates >/dev/null ;;
    dnf) dnf install -y curl git tar openssl openssh-clients ca-certificates >/dev/null ;;
    yum) yum install -y curl git tar openssl openssh-clients ca-certificates >/dev/null ;;
  esac
  ok "Prerequisites ready."
}

# The main template of both panels (index.php / admin/index.php) is rendered
# by PHP; the Node.js server detects and executes it automatically. If PHP
# fails to install here, installation does not stop — the service keeps
# working fine by serving the same two files as static HTML instead
# (server.js falls back automatically).
install_php(){
  info "Installing PHP CLI..."
  local pm; pm=$(detect_pkg_manager)
  case "$pm" in
    apt) apt-get install -y php-cli >/dev/null 2>&1 ;;
    dnf) dnf install -y php-cli >/dev/null 2>&1 ;;
    yum) yum install -y php-cli >/dev/null 2>&1 ;;
  esac
  if command -v php >/dev/null 2>&1; then
    ok "PHP $(php -v 2>/dev/null | head -n1 | awk '{print $2}') installed."
  else
    warn "PHP installation failed — no problem, the same two pages will be served as static HTML instead."
  fi
}

node_version_ok(){
  command -v node >/dev/null 2>&1 || return 1
  local v; v=$(node -v 2>/dev/null | sed 's/^v//')
  local major=${v%%.*}
  [[ "$major" -ge "$NODE_MAJOR" ]]
}

install_node(){
  if node_version_ok; then
    ok "Node.js $(node -v) is already installed and sufficient."
    return
  fi
  info "Installing Node.js ${NODE_MAJOR}.x via NodeSource..."
  local pm; pm=$(detect_pkg_manager)
  if [[ "$pm" == "apt" ]]; then
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - >/dev/null
    apt-get install -y nodejs >/dev/null
  else
    curl -fsSL "https://rpm.nodesource.com/setup_${NODE_MAJOR}.x" | bash - >/dev/null
    "$pm" install -y nodejs >/dev/null
  fi
  node_version_ok || die "Node.js installation failed — current version: $(node -v 2>/dev/null || echo 'not found')."
  ok "Node.js $(node -v) installed."
}

random_password(){
  # secure random password — the hardcoded default password is never used
  openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 20
}
random_admin_path(){
  # random, unguessable path for the admin panel (e.g. panel-9f3a7c1d) instead
  # of the fixed, guessable /admin — only ever shown via "dotinschool admin".
  echo "panel-$(openssl rand -hex 6)"
}

DEPLOY_KEY="/root/.ssh/dotinschool_deploy"

# "owner/repo" از REPO_URL (git@github.com:owner/repo.git) استخراج می‌کند —
# برای صدا زدن GitHub API لازم است.
repo_owner_name(){
  local u="$REPO_URL"
  u="${u#git@github.com:}"
  u="${u%.git}"
  echo "$u"
}

# نصب GitHub CLI (gh) اگر از قبل نباشد — فقط برای اضافه‌کردن خودکار Deploy
# Key لازم است، هیچ اجباری نیست (اگر نصب نشود، مسیر دستی همچنان کار می‌کند).
install_gh_cli(){
  command -v gh >/dev/null 2>&1 && return 0
  info "Installing GitHub CLI (gh)..."
  local pm; pm=$(detect_pkg_manager)
  case "$pm" in
    apt)
      mkdir -p -m 755 /etc/apt/keyrings
      curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg 2>/dev/null || return 1
      chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
      apt-get update -y >/dev/null 2>&1
      apt-get install -y gh >/dev/null 2>&1
      ;;
    dnf) dnf install -y 'dnf-command(config-manager)' >/dev/null 2>&1; dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo >/dev/null 2>&1; dnf install -y gh >/dev/null 2>&1 ;;
    yum) yum-config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo >/dev/null 2>&1; yum install -y gh >/dev/null 2>&1 ;;
  esac
  command -v gh >/dev/null 2>&1
}

# لاگین دستگاهی (device flow) گیت‌هاب: یک کد و یک آدرس نشان داده می‌شود، کاربر
# آن آدرس را با هر مرورگری (مثلاً گوشی‌اش، نه لزوماً همین سرور) باز می‌کند و
# کد را وارد می‌کند — هیچ توکنی داخل خودِ اسکریپت نوشته نمی‌شود؛ gh آن را
# موقتاً در کانفیگ خودش نگه می‌دارد و بلافاصله بعد از همین یک درخواست API،
# logout انجام می‌شود تا چیزی روی دیسک سرور باقی نماند.
try_auto_add_deploy_key(){
  install_gh_cli || { warn "Could not install GitHub CLI — falling back to manual."; return 1; }
  info "GitHub login — a one-time code and a URL will appear below; open the URL on any device (your phone works fine) and enter the code."
  gh auth login --hostname github.com --git-protocol https --web || { warn "GitHub login was not completed."; return 1; }
  local slug title
  slug=$(repo_owner_name)
  title="dotinschool-$(hostname 2>/dev/null || echo server)-$(date +%s)"
  if gh api "repos/${slug}/keys" -f "title=${title}" -f "key=$(cat "${DEPLOY_KEY}.pub")" -F read_only=true >/dev/null 2>&1; then
    ok "Deploy key added to ${slug} via GitHub API."
    gh auth logout --hostname github.com --user "$(gh api user -q .login 2>/dev/null)" 2>/dev/null || true
    return 0
  else
    warn "GitHub API rejected the request (maybe insufficient token scope)."
    gh auth logout --hostname github.com --user "$(gh api user -q .login 2>/dev/null)" 2>/dev/null || true
    return 1
  fi
}

# این تابع خودِ نیازمندی (دسترسی SSH به ریپوی خصوصی) را پوشش می‌دهد — دیگر
# لازم نیست کاربر قبل از اجرای دستور نصب، جدا کلید بسازد: اگر کلیدی نبود
# همین‌جا ساخته می‌شود، سپس تلاش می‌کند خودش (با لاگین گیت‌هاب) به ریپو
# اضافه‌اش کند و با یک درخواست واقعی تأییدیه بگیرد؛ اگر این مسیر ممکن نبود
# (کاربر انصراف داد یا gh نصب نشد)، کلید را نشان می‌دهد و دستی منتظر می‌ماند —
# به‌جای شکست خوردن ناگهانی با خطای خام «Permission denied» گیت.
ensure_deploy_key(){
  mkdir -p "$(dirname "$DEPLOY_KEY")"
  if [[ ! -f "$DEPLOY_KEY" ]]; then
    info "No deploy key found on this server — generating one..."
    ssh-keygen -t ed25519 -f "$DEPLOY_KEY" -N "" -q
    ok "Deploy key generated."
  fi
  export GIT_SSH_COMMAND="ssh -i ${DEPLOY_KEY} -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
  if git ls-remote "$REPO_URL" >/dev/null 2>&1; then
    return 0
  fi

  warn "This server's key is not yet authorized on the GitHub repository."
  read -r -p "Add it automatically via GitHub login? [Y/n]: " autoadd
  if [[ "$autoadd" != "n" && "$autoadd" != "N" ]]; then
    if try_auto_add_deploy_key && git ls-remote "$REPO_URL" >/dev/null 2>&1; then
      ok "Access to the repository confirmed."
      return 0
    fi
    warn "Automatic setup didn't complete — switching to the manual method."
  fi

  echo
  echo -e "${BOLD}Add this key as a Deploy Key:${NC} repo page on GitHub → Settings → Deploy keys → Add deploy key (read-only access is enough)"
  echo
  echo -e "${CYAN}$(cat "${DEPLOY_KEY}.pub")${NC}"
  echo
  while ! git ls-remote "$REPO_URL" >/dev/null 2>&1; do
    read -r -p "Press Enter after adding the key above to retry (Ctrl+C to abort)... " _
    if git ls-remote "$REPO_URL" >/dev/null 2>&1; then break; fi
    warn "Still can't access the repository — double-check the key was pasted in full, then try again."
  done
  ok "Access to the repository confirmed."
}

fetch_app(){
  ensure_deploy_key
  if [[ -d "$INSTALL_DIR/.git" ]]; then
    info "Updating source from ${REPO_URL} (${BRANCH})..."
    git -C "$INSTALL_DIR" fetch --depth 1 origin "$BRANCH" >/dev/null
    git -C "$INSTALL_DIR" reset --hard "origin/${BRANCH}" >/dev/null
  else
    info "Fetching source from ${REPO_URL} (${BRANCH})..."
    rm -rf "$INSTALL_DIR"
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$INSTALL_DIR" >/dev/null
  fi
  ok "Source ready in ${INSTALL_DIR}."
}

write_env_file(){
  # only create the env file if it doesn't already exist (so an existing
  # password/port is never overwritten)
  mkdir -p "$CONFIG_DIR"
  if [[ ! -f "$ENV_FILE" ]]; then
    local pass adminpath
    pass=$(random_password)
    adminpath=$(random_admin_path)
    cat > "$ENV_FILE" <<EOF
# dotinschool service configuration — edit via "dotinschool admin" or "dotinschool cert"
PORT=8080
DATA_DIR=${INSTALL_DIR}/data
ADMIN_USERNAME=administrator
ADMIN_PASSWORD=${pass}
ADMIN_PATH=${adminpath}
# SSL_CERT_PATH=
# SSL_KEY_PATH=
EOF
    chmod 600 "$ENV_FILE"
    ok "Configuration file created — a random admin password and secret admin path were generated."
  fi
}

write_systemd_unit(){
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=dotinschool — programming challenge platform
After=network.target

[Service]
Type=simple
EnvironmentFile=${ENV_FILE}
WorkingDirectory=${INSTALL_DIR}
ExecStart=$(command -v node) ${INSTALL_DIR}/server.js
Restart=always
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  ok "systemd service written."
}

open_firewall_port(){
  local port="$1"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${port}/tcp" >/dev/null 2>&1 || true
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

install_cli(){
  cp "${INSTALL_DIR}/install.sh" "$CLI_PATH"
  chmod +x "$CLI_PATH"
  ok "The \"dotinschool\" management command was installed."
}

get_env_val(){ grep -E "^${1}=" "$ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2-; }
set_env_val(){
  local key="$1" val="$2"
  if grep -qE "^${key}=" "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
  else
    echo "${key}=${val}" >> "$ENV_FILE"
  fi
}

server_ip(){ curl -fsSL -4 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}'; }

print_access_info(){
  local port scheme ip adminpath subdomain
  port=$(get_env_val PORT); scheme="http"
  [[ -n "$(get_env_val SSL_CERT_PATH)" ]] && scheme="https"
  ip=$(server_ip)
  adminpath=$(get_env_val ADMIN_PATH); adminpath=${adminpath:-admin}
  subdomain=$(get_env_val ADMIN_SUBDOMAIN)
  echo
  ok "User panel (public address — everyone sees this): ${scheme}://${ip}:${port}/"
  ok "Admin panel (secret path — only you):              ${scheme}://${ip}:${port}/${adminpath}/"
  if [[ -n "$subdomain" ]]; then
    ok "Admin panel (dedicated subdomain):                 ${scheme}://${subdomain}/"
  fi
  ok "Admin username:                                     $(get_env_val ADMIN_USERNAME)"
  ok "Admin password:                                     $(get_env_val ADMIN_PASSWORD)"
  echo
  warn "Save this information somewhere safe — it's only viewable/changeable again via \"dotinschool admin\"."
}

cmd_install(){
  require_root
  install_prereqs
  install_node
  install_php
  fetch_app
  write_env_file
  write_systemd_unit
  install_cli
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
  systemctl restart "$SERVICE_NAME"
  sleep 1
  open_firewall_port "$(get_env_val PORT)"
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    ok "Installation complete and the service is running."
  else
    err "The service failed to start — log output:"
    journalctl -u "$SERVICE_NAME" --no-pager -n 30 || true
    exit 1
  fi
  print_access_info
}

cmd_update(){
  require_root
  [[ -d "$INSTALL_DIR" ]] || die "Not installed yet — run \"dotinschool install\" first."
  fetch_app
  install_cli
  systemctl restart "$SERVICE_NAME"
  ok "Update complete and the service was restarted."
}

cmd_uninstall(){
  require_root
  read -r -p "$(echo -e ${YELLOW}This will remove the service, installed files, and configuration. Are you sure? [y/N]${NC}) " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || { info "Cancelled."; return; }
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload
  rm -rf "$INSTALL_DIR" "$CONFIG_DIR" "$CLI_PATH"
  ok "dotinschool was completely removed."
}

cmd_admin(){
  require_root
  [[ -f "$ENV_FILE" ]] || die "Not installed yet."
  echo "1) Show current access info (admin panel secret address + username/password)"
  echo "2) Change username"
  echo "3) Change password (random)"
  echo "4) Change port"
  echo "5) Change the admin panel's secret path (new random one — if it leaked)"
  echo "6) Set/change the admin panel's dedicated subdomain (like a Sanaei panel)"
  read -r -p "Choice: " choice
  case "$choice" in
    1) print_access_info ;;
    2) read -r -p "New username: " u; set_env_val ADMIN_USERNAME "$u"; systemctl restart "$SERVICE_NAME"; ok "Username changed."; print_access_info ;;
    3) local p; p=$(random_password); set_env_val ADMIN_PASSWORD "$p"; systemctl restart "$SERVICE_NAME"; ok "New password generated."; print_access_info ;;
    4) read -r -p "New port: " p; set_env_val PORT "$p"; open_firewall_port "$p"; systemctl restart "$SERVICE_NAME"; ok "Port changed."; print_access_info ;;
    5) local np; np=$(random_admin_path); set_env_val ADMIN_PATH "$np"; systemctl restart "$SERVICE_NAME"; ok "Admin panel secret path changed — the old address no longer works."; print_access_info ;;
    6)
      read -r -p "Full subdomain (e.g. panel.example.com; empty = disable): " sd
      set_env_val ADMIN_SUBDOMAIN "$sd"
      systemctl restart "$SERVICE_NAME"
      if [[ -n "$sd" ]]; then
        ok "Subdomain set."
        warn "For this to work, add a DNS A record for \"${sd}\" pointing to this server's IP. If you want SSL, run \"dotinschool cert\" again so this subdomain is covered by the certificate too."
      else
        ok "Subdomain disabled — only the secret path works now."
      fi
      print_access_info
      ;;
    *) warn "Invalid option." ;;
  esac
}

install_acme(){
  if [[ ! -x "$HOME/.acme.sh/acme.sh" ]]; then
    info "Installing acme.sh..."
    curl -fsSL https://get.acme.sh | sh -s email="admin@$(hostname -f 2>/dev/null || echo localhost)" >/dev/null 2>&1
  fi
}

cmd_cert(){
  require_root
  echo "Getting an SSL certificate requires a domain whose DNS A record already points to this server's IP."
  warn "If you're only accessing this via a raw IP and have no domain, skip this step — the panel keeps working over plain HTTP with no certificate errors."
  read -r -p "Domain (empty = cancel): " domain
  [[ -n "$domain" ]] || { info "Cancelled."; return; }

  local domain_args=(-d "$domain")
  local subdomain; subdomain=$(get_env_val ADMIN_SUBDOMAIN)
  local subdomain_included=""
  if [[ -n "$subdomain" && "$subdomain" != "$domain" ]]; then
    read -r -p "Also cover the admin subdomain (${subdomain}) with this same certificate? Its DNS must also point to this server. [Y/n]: " inc
    if [[ "$inc" != "n" && "$inc" != "N" ]]; then
      domain_args+=(-d "$subdomain")
      subdomain_included="1"
    fi
  fi

  install_acme
  mkdir -p "${SSL_DIR}/${domain}"

  info "Temporarily stopping the service to free port 80 (standalone method)..."
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true

  if ! "$HOME/.acme.sh/acme.sh" --issue "${domain_args[@]}" --standalone --httpport 80; then
    err "Certificate issuance failed — make sure all domains above point to this server's IP and port 80 is free."
    systemctl start "$SERVICE_NAME" 2>/dev/null || true
    return 1
  fi

  "$HOME/.acme.sh/acme.sh" --install-cert -d "$domain" \
    --fullchain-file "${SSL_DIR}/${domain}/fullchain.pem" \
    --key-file "${SSL_DIR}/${domain}/privkey.pem" \
    --reloadcmd "systemctl restart ${SERVICE_NAME}" >/dev/null

  set_env_val SSL_CERT_PATH "${SSL_DIR}/${domain}/fullchain.pem"
  set_env_val SSL_KEY_PATH "${SSL_DIR}/${domain}/privkey.pem"
  set_env_val PORT 443
  open_firewall_port 443

  systemctl start "$SERVICE_NAME"
  sleep 1
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    ok "Certificate issued and active — the panel is now running on HTTPS (auto-renewed by acme.sh)."
    local adminpath; adminpath=$(get_env_val ADMIN_PATH); adminpath=${adminpath:-admin}
    echo
    ok "User panel: https://${domain}/"
    ok "Admin panel: https://${domain}/${adminpath}/"
    [[ -n "$subdomain_included" ]] && ok "Admin panel (subdomain): https://${subdomain}/"
  else
    err "The service failed to start with HTTPS — check the log: journalctl -u ${SERVICE_NAME} -n 50"
  fi
}

cmd_service(){
  require_root
  systemctl "$1" "$SERVICE_NAME"
  [[ "$1" == "status" ]] || ok "Command \"$1\" applied to the service."
}

show_menu(){
  echo -e "${BOLD}=================================================${NC}"
  echo -e "${BOLD}   dotinschool — management menu${NC}"
  echo -e "${BOLD}=================================================${NC}"
  echo " 1) Install"
  echo " 2) Update to the latest version"
  echo " 3) Show/change admin panel info"
  echo " 4) Get an SSL certificate for a domain"
  echo " 5) Start"
  echo " 6) Stop"
  echo " 7) Restart"
  echo " 8) Service status"
  echo " 9) Enable auto-start on boot"
  echo "10) Disable auto-start"
  echo "11) Uninstall completely"
  echo " 0) Exit"
  echo -e "${BOLD}=================================================${NC}"
  read -r -p "Choice: " choice
  case "$choice" in
    1) cmd_install ;;
    2) cmd_update ;;
    3) cmd_admin ;;
    4) cmd_cert ;;
    5) cmd_service start ;;
    6) cmd_service stop ;;
    7) cmd_service restart ;;
    8) cmd_service status ;;
    9) require_root; systemctl enable "$SERVICE_NAME" >/dev/null; ok "Auto-start enabled." ;;
    10) require_root; systemctl disable "$SERVICE_NAME" >/dev/null; ok "Auto-start disabled." ;;
    11) cmd_uninstall ;;
    0) exit 0 ;;
    *) warn "Invalid option." ;;
  esac
}

main(){
  case "${1:-}" in
    install) cmd_install ;;
    update) cmd_update ;;
    uninstall) cmd_uninstall ;;
    admin) cmd_admin ;;
    cert) cmd_cert ;;
    start|stop|restart|status) cmd_service "$1" ;;
    enable) require_root; systemctl enable "$SERVICE_NAME" >/dev/null; ok "Auto-start enabled." ;;
    disable) require_root; systemctl disable "$SERVICE_NAME" >/dev/null; ok "Auto-start disabled." ;;
    "") show_menu ;;
    *) die "Invalid command: $1" ;;
  esac
}

main "$@"
