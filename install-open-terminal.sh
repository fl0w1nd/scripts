#!/bin/bash
set -euo pipefail

# ============================================================
#  Open Terminal - Interactive Installer
#  https://github.com/open-webui/open-terminal
#
#  Supports: Debian/Ubuntu, RHEL/CentOS/Fedora, Arch, macOS
#  Features: venv install, systemd/launchd auto-start,
#            auto-update timer, interactive configuration
# ============================================================

VERSION="1.0.0"
INSTALL_DIR="/opt/open-terminal"
CONFIG_DIR="/etc/open-terminal"
CONFIG_FILE="$CONFIG_DIR/config.toml"
VENV_DIR="$INSTALL_DIR/venv"
SERVICE_NAME="open-terminal"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

banner() {
    echo -e "${CYAN}${BOLD}"
    cat << 'EOF'
   ___                    _____                   _             _
  / _ \ _ __   ___ _ __  |_   _|__ _ __ _ __ ___ (_)_ __   __ _| |
 | | | | '_ \ / _ \ '_ \   | |/ _ \ '__| '_ ` _ \| | '_ \ / _` | |
 | |_| | |_) |  __/ | | |  | |  __/ |  | | | | | | | | | | (_| | |
  \___/| .__/ \___|_| |_|  |_|\___|_|  |_| |_| |_|_|_| |_|\__,_|_|
       |_|
EOF
    echo -e "${NC}"
    echo -e "  ${BOLD}Interactive Installer v${VERSION}${NC}"
    echo ""
}

# --- Detect OS ---
detect_os() {
    case "$(uname -s)" in
        Linux*)
            OS="linux"
            if [ -f /etc/os-release ]; then
                . /etc/os-release
                DISTRO="$ID"
            else
                DISTRO="unknown"
            fi
            ARCH="$(uname -m)"
            ;;
        Darwin*)
            OS="macos"
            DISTRO="macos"
            ARCH="$(uname -m)"
            ;;
        *)
            error "Unsupported OS: $(uname -s)"
            ;;
    esac
    info "Detected: ${BOLD}$OS${NC} ($DISTRO) - $ARCH"
}

# --- Check root (Linux only) ---
check_root() {
    if [ "$OS" = "linux" ] && [ "$EUID" -ne 0 ]; then
        error "Please run as root: sudo bash $0"
    fi
}

# --- Check prerequisites ---
check_prerequisites() {
    info "Checking prerequisites..."

    # Python 3
    if command -v python3 &>/dev/null; then
        PYTHON_BIN="$(command -v python3)"
        PYTHON_VER="$($PYTHON_BIN --version 2>&1 | awk '{print $2}')"
        PYTHON_MAJOR="${PYTHON_VER%%.*}"
        PYTHON_MINOR="${PYTHON_VER#*.}"; PYTHON_MINOR="${PYTHON_MINOR%%.*}"

        if [ "$PYTHON_MAJOR" -lt 3 ] || { [ "$PYTHON_MAJOR" -eq 3 ] && [ "$PYTHON_MINOR" -lt 11 ]; }; then
            error "Python >= 3.11 required (found $PYTHON_VER)"
        fi
        success "Python $PYTHON_VER"
    else
        error "Python 3 not found. Please install Python 3.11+ first."
    fi

    # venv module
    if ! $PYTHON_BIN -m venv --help &>/dev/null; then
        warn "Python venv module not found, attempting to install..."
        case "$DISTRO" in
            debian|ubuntu|raspbian)
                apt-get update -qq && apt-get install -y -qq python3-venv ;;
            fedora|centos|rhel|rocky|alma)
                dnf install -y python3-venv 2>/dev/null || yum install -y python3-venv ;;
            arch|manjaro)
                pacman -Sy --noconfirm python ;;
            macos)
                error "venv should be included with Python on macOS. Reinstall Python via brew." ;;
        esac
        success "Python venv module installed"
    else
        success "Python venv module"
    fi

    # systemd (Linux) / launchd (macOS)
    if [ "$OS" = "linux" ]; then
        command -v systemctl &>/dev/null || error "systemd not found."
        success "systemd"
    else
        success "launchd (macOS)"
    fi
}

# --- Check existing installation ---
is_installed() {
    [ -d "$VENV_DIR" ] && [ -f "$VENV_DIR/bin/open-terminal" ]
}

get_current_version() {
    if is_installed; then
        "$VENV_DIR/bin/pip" show open-terminal 2>/dev/null | grep ^Version | awk '{print $2}'
    fi
}

get_service_status() {
    if [ "$OS" = "linux" ]; then
        systemctl is-active ${SERVICE_NAME}.service 2>/dev/null || echo "inactive"
    else
        if launchctl list 2>/dev/null | grep -q com.open-terminal; then
            echo "active"
        else
            echo "inactive"
        fi
    fi
}

# --- Management menu (shown when already installed) ---
management_menu() {
    local current_ver
    current_ver=$(get_current_version)
    local status
    status=$(get_service_status)

    echo -e "${BOLD}Existing installation detected${NC}"
    echo -e "  Version: ${GREEN}v${current_ver}${NC}"
    echo -e "  Status:  ${GREEN}${status}${NC}"
    [ -f "$CONFIG_FILE" ] && echo -e "  Config:  ${CYAN}${CONFIG_FILE}${NC}"
    echo ""
    echo -e "${BOLD}What would you like to do?${NC}"
    echo -e "  ${CYAN}1${NC}) Reconfigure  (change port / listen address / API key)"
    echo -e "  ${CYAN}2${NC}) Update        (upgrade to latest version)"
    echo -e "  ${CYAN}3${NC}) Reinstall     (remove and install from scratch)"
    echo -e "  ${CYAN}4${NC}) Uninstall     (remove everything)"
    echo -e "  ${CYAN}5${NC}) Quit"
    echo ""
    read -rp "$(echo -e "${YELLOW}Choose [1-5]:${NC} ")" MGMT_CHOICE

    case "$MGMT_CHOICE" in
        1) action_reconfigure ;;
        2) action_update ;;
        3) action_uninstall && fresh_install ;;
        4) action_uninstall; echo ""; success "Uninstall complete."; exit 0 ;;
        5) exit 0 ;;
        *) error "Invalid choice" ;;
    esac
}

action_reconfigure() {
    configure
    write_config
    # Restart service to pick up new config
    if [ "$OS" = "linux" ]; then
        systemctl restart ${SERVICE_NAME}.service 2>/dev/null && success "Service restarted with new config"
    else
        launchctl kickstart -k gui/$(id -u)/com.open-terminal 2>/dev/null && success "Service restarted with new config"
    fi
    print_status
    exit 0
}

action_update() {
    info "Checking for updates ..."
    "$VENV_DIR/bin/pip" install --upgrade open-terminal -q
    local new_ver
    new_ver=$(get_current_version)
    success "Now at v${new_ver}"
    # Restart service
    if [ "$OS" = "linux" ]; then
        systemctl restart ${SERVICE_NAME}.service 2>/dev/null
    else
        launchctl kickstart -k gui/$(id -u)/com.open-terminal 2>/dev/null
    fi
    success "Service restarted"
    exit 0
}

action_uninstall() {
    warn "Removing Open Terminal ..."
    if [ "$OS" = "linux" ]; then
        systemctl disable --now ${SERVICE_NAME}.service 2>/dev/null || true
        systemctl disable --now ${SERVICE_NAME}-update.timer 2>/dev/null || true
        rm -f /etc/systemd/system/${SERVICE_NAME}*.service
        rm -f /etc/systemd/system/${SERVICE_NAME}*.timer
        systemctl daemon-reload 2>/dev/null || true
    else
        launchctl bootout gui/$(id -u) "$HOME/Library/LaunchAgents/com.open-terminal.plist" 2>/dev/null || true
        launchctl bootout gui/$(id -u) "$HOME/Library/LaunchAgents/com.open-terminal.update.plist" 2>/dev/null || true
        rm -f "$HOME/Library/LaunchAgents/com.open-terminal"*.plist
    fi
    rm -rf "$INSTALL_DIR"
    rm -rf "$CONFIG_DIR"
    success "All files and services removed"
}

print_status() {
    echo ""
    echo -e "${GREEN}${BOLD}============================================${NC}"
    echo -e "${GREEN}${BOLD}  Done!${NC}"
    echo -e "${GREEN}${BOLD}============================================${NC}"
    echo ""
    echo -e "  URL:     ${BOLD}http://${HOST}:${PORT}${NC}"
    echo -e "  API Key: ${BOLD}${API_KEY}${NC}"
    echo -e "  Docs:    ${BOLD}http://${HOST}:${PORT}/docs${NC}"
    echo ""
}

# --- Interactive configuration ---
configure() {
    echo ""
    echo -e "${BOLD}--- Configuration ---${NC}"
    echo ""

    # Load existing values as defaults
    local old_port="8000" old_host="0.0.0.0" old_key="" old_cors="*"
    if [ -f "$CONFIG_FILE" ]; then
        old_port=$(grep '^port' "$CONFIG_FILE" 2>/dev/null | sed 's/[^0-9]//g' || echo "8000")
        old_host=$(grep '^host' "$CONFIG_FILE" 2>/dev/null | sed 's/.*"\(.*\)"/\1/' || echo "0.0.0.0")
        old_key=$(grep '^api_key' "$CONFIG_FILE" 2>/dev/null | sed 's/.*"\(.*\)"/\1/' || echo "")
        old_cors=$(grep '^cors' "$CONFIG_FILE" 2>/dev/null | sed 's/.*"\(.*\)"/\1/' || echo "*")
    fi

    # Port
    read -rp "$(echo -e "${CYAN}Port${NC} [${old_port}]: ")" INPUT_PORT
    PORT="${INPUT_PORT:-$old_port}"

    # Listen address - simple choice
    echo ""
    echo -e "  ${CYAN}1${NC}) 0.0.0.0    - Listen on all interfaces (LAN accessible)"
    echo -e "  ${CYAN}2${NC}) 127.0.0.1  - Localhost only (more secure)"
    echo ""
    local host_default="1"
    [ "$old_host" = "127.0.0.1" ] && host_default="2"
    read -rp "$(echo -e "${CYAN}Listen address${NC} [${host_default}]: ")" INPUT_HOST
    INPUT_HOST="${INPUT_HOST:-$host_default}"
    case "$INPUT_HOST" in
        2) HOST="127.0.0.1" ;;
        *) HOST="0.0.0.0" ;;
    esac

    # API Key
    if [ -n "$old_key" ]; then
        local masked="${old_key:0:6}...${old_key: -4}"
        echo ""
        echo -e "  Current API Key: ${GREEN}${masked}${NC}"
        read -rp "$(echo -e "${CYAN}API Key${NC} [keep current / enter new / 'gen' to regenerate]: ")" INPUT_KEY
        case "$INPUT_KEY" in
            "") API_KEY="$old_key" ;;
            gen|GEN) API_KEY="sk-$(python3 -c 'import secrets; print(secrets.token_hex(24))')" ;;
            *) API_KEY="$INPUT_KEY" ;;
        esac
    else
        DEFAULT_KEY="sk-$(python3 -c 'import secrets; print(secrets.token_hex(24))')"
        read -rp "$(echo -e "${CYAN}API Key${NC} [auto-generated]: ")" INPUT_KEY
        API_KEY="${INPUT_KEY:-$DEFAULT_KEY}"
    fi

    # CORS
    read -rp "$(echo -e "${CYAN}CORS allowed origins${NC} [${old_cors}]: ")" INPUT_CORS
    CORS="${INPUT_CORS:-$old_cors}"

    # Auto-update
    read -rp "$(echo -e "${CYAN}Enable auto-update?${NC} [Y/n]: ")" INPUT_UPDATE
    case "${INPUT_UPDATE,,}" in
        n|no) AUTO_UPDATE=false ;;
        *)    AUTO_UPDATE=true ;;
    esac

    if [ "$AUTO_UPDATE" = true ]; then
        read -rp "$(echo -e "${CYAN}Update check interval (hours)${NC} [6]: ")" INPUT_INTERVAL
        UPDATE_INTERVAL="${INPUT_INTERVAL:-6}"
    fi

    # Confirm
    echo ""
    echo -e "${BOLD}--- Summary ---${NC}"
    echo -e "  Listen:      ${GREEN}${HOST}:${PORT}${NC}"
    echo -e "  API Key:     ${GREEN}${API_KEY}${NC}"
    echo -e "  CORS:        ${GREEN}${CORS}${NC}"
    echo -e "  Auto-update: ${GREEN}${AUTO_UPDATE}${NC}"
    [ "$AUTO_UPDATE" = true ] && echo -e "  Interval:    ${GREEN}every ${UPDATE_INTERVAL}h${NC}"
    echo ""

    read -rp "$(echo -e "${YELLOW}Proceed? [Y/n]:${NC} ")" CONFIRM
    case "${CONFIRM,,}" in
        n|no) echo "Aborted."; exit 0 ;;
    esac
}

# --- Install ---
install_open_terminal() {
    info "Creating virtual environment at $VENV_DIR ..."
    mkdir -p "$INSTALL_DIR"
    $PYTHON_BIN -m venv "$VENV_DIR"
    success "Virtual environment created"

    info "Installing open-terminal via pip ..."
    "$VENV_DIR/bin/pip" install --upgrade pip -q
    "$VENV_DIR/bin/pip" install open-terminal -q
    OT_VERSION=$("$VENV_DIR/bin/pip" show open-terminal | grep ^Version | awk '{print $2}')
    success "open-terminal v${OT_VERSION} installed"
}

# --- Write config ---
write_config() {
    info "Writing config to $CONFIG_FILE ..."
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" << EOF
host = "$HOST"
port = $PORT
api_key = "$API_KEY"
cors_allowed_origins = "$CORS"
EOF
    chmod 600 "$CONFIG_FILE"
    success "Config written"
}

# --- Setup systemd (Linux) ---
setup_systemd_service() {
    info "Creating systemd service ..."

    cat > /etc/systemd/system/${SERVICE_NAME}.service << EOF
[Unit]
Description=Open Terminal - AI Agent Terminal API
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${VENV_DIR}/bin/open-terminal run
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now ${SERVICE_NAME}.service
    success "Service enabled and started"
}

# --- Setup launchd (macOS) ---
setup_launchd_service() {
    info "Creating launchd service ..."

    PLIST_DIR="$HOME/Library/LaunchAgents"
    PLIST_FILE="$PLIST_DIR/com.open-terminal.plist"
    LOG_DIR="$HOME/Library/Logs/open-terminal"
    mkdir -p "$PLIST_DIR" "$LOG_DIR"

    cat > "$PLIST_FILE" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.open-terminal</string>
    <key>ProgramArguments</key>
    <array>
        <string>${VENV_DIR}/bin/open-terminal</string>
        <string>run</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/stderr.log</string>
</dict>
</plist>
EOF

    launchctl bootout gui/$(id -u) "$PLIST_FILE" 2>/dev/null || true
    launchctl bootstrap gui/$(id -u) "$PLIST_FILE"
    success "LaunchAgent enabled and started"
}

# --- Auto-update: systemd timer (Linux) ---
setup_systemd_updater() {
    info "Creating auto-update script and timer ..."

    cat > "$INSTALL_DIR/update.sh" << 'SCRIPT'
#!/bin/bash
VENV_PIP="__VENV_DIR__/bin/pip"
LOG_TAG="open-terminal-update"

CURRENT=$($VENV_PIP show open-terminal 2>/dev/null | grep ^Version | awk '{print $2}')
LATEST=$($VENV_PIP index versions open-terminal 2>/dev/null | head -1 | grep -oP '\(\K[^)]+')

if [ -z "$LATEST" ]; then
    logger -t "$LOG_TAG" "Failed to check latest version"
    exit 1
fi
if [ "$CURRENT" = "$LATEST" ]; then
    logger -t "$LOG_TAG" "Already up to date: v$CURRENT"
    exit 0
fi

logger -t "$LOG_TAG" "Updating from v$CURRENT to v$LATEST ..."
$VENV_PIP install --upgrade open-terminal -q 2>&1

if [ $? -eq 0 ]; then
    logger -t "$LOG_TAG" "Update successful, restarting service"
    systemctl restart open-terminal.service
else
    logger -t "$LOG_TAG" "Update failed"
    exit 1
fi
SCRIPT
    sed -i "s|__VENV_DIR__|${VENV_DIR}|g" "$INSTALL_DIR/update.sh"
    chmod +x "$INSTALL_DIR/update.sh"

    cat > /etc/systemd/system/${SERVICE_NAME}-update.service << EOF
[Unit]
Description=Open Terminal Auto Update

[Service]
Type=oneshot
ExecStart=${INSTALL_DIR}/update.sh
EOF

    cat > /etc/systemd/system/${SERVICE_NAME}-update.timer << EOF
[Unit]
Description=Check for Open Terminal updates every ${UPDATE_INTERVAL} hours

[Timer]
OnBootSec=5min
OnUnitActiveSec=${UPDATE_INTERVAL}h
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now ${SERVICE_NAME}-update.timer
    success "Auto-update timer enabled (every ${UPDATE_INTERVAL}h)"
}

# --- Auto-update: launchd (macOS) ---
setup_launchd_updater() {
    info "Creating auto-update script and LaunchAgent ..."

    cat > "$INSTALL_DIR/update.sh" << 'SCRIPT'
#!/bin/bash
VENV_PIP="__VENV_DIR__/bin/pip"
LOG_FILE="__LOG_DIR__/update.log"
TS=$(date '+%Y-%m-%d %H:%M:%S')

CURRENT=$($VENV_PIP show open-terminal 2>/dev/null | grep ^Version | awk '{print $2}')
LATEST=$($VENV_PIP index versions open-terminal 2>/dev/null | head -1 | sed -n 's/.*(\([^)]*\)).*/\1/p')

if [ -z "$LATEST" ]; then
    echo "[$TS] Failed to check latest version" >> "$LOG_FILE"
    exit 1
fi
if [ "$CURRENT" = "$LATEST" ]; then
    echo "[$TS] Already up to date: v$CURRENT" >> "$LOG_FILE"
    exit 0
fi

echo "[$TS] Updating from v$CURRENT to v$LATEST ..." >> "$LOG_FILE"
$VENV_PIP install --upgrade open-terminal -q 2>&1

if [ $? -eq 0 ]; then
    echo "[$TS] Update successful, restarting service" >> "$LOG_FILE"
    launchctl kickstart -k gui/$(id -u)/com.open-terminal
else
    echo "[$TS] Update failed" >> "$LOG_FILE"
    exit 1
fi
SCRIPT
    sed -i '' "s|__VENV_DIR__|${VENV_DIR}|g" "$INSTALL_DIR/update.sh" 2>/dev/null \
        || sed -i "s|__VENV_DIR__|${VENV_DIR}|g" "$INSTALL_DIR/update.sh"
    LOG_DIR="$HOME/Library/Logs/open-terminal"
    sed -i '' "s|__LOG_DIR__|${LOG_DIR}|g" "$INSTALL_DIR/update.sh" 2>/dev/null \
        || sed -i "s|__LOG_DIR__|${LOG_DIR}|g" "$INSTALL_DIR/update.sh"
    chmod +x "$INSTALL_DIR/update.sh"

    INTERVAL_SECONDS=$((UPDATE_INTERVAL * 3600))
    PLIST_DIR="$HOME/Library/LaunchAgents"
    PLIST_FILE="$PLIST_DIR/com.open-terminal.update.plist"

    cat > "$PLIST_FILE" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.open-terminal.update</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_DIR}/update.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>${INTERVAL_SECONDS}</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/update-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/update-stderr.log</string>
</dict>
</plist>
EOF

    launchctl bootout gui/$(id -u) "$PLIST_FILE" 2>/dev/null || true
    launchctl bootstrap gui/$(id -u) "$PLIST_FILE"
    success "Auto-update LaunchAgent enabled (every ${UPDATE_INTERVAL}h)"
}

# --- Fresh install flow ---
fresh_install() {
    check_prerequisites
    configure
    install_open_terminal
    write_config

    if [ "$OS" = "linux" ]; then
        setup_systemd_service
        [ "$AUTO_UPDATE" = true ] && setup_systemd_updater
    else
        setup_launchd_service
        [ "$AUTO_UPDATE" = true ] && setup_launchd_updater
    fi

    print_status

    echo -e "  Config:  ${CYAN}${CONFIG_FILE}${NC}"
    echo -e "  venv:    ${CYAN}${VENV_DIR}${NC}"

    if [ "$OS" = "linux" ]; then
        echo ""
        echo -e "  ${BOLD}Useful commands:${NC}"
        echo -e "    systemctl status open-terminal"
        echo -e "    journalctl -u open-terminal -f"
        [ "$AUTO_UPDATE" = true ] && echo -e "    journalctl -t open-terminal-update"
    else
        echo ""
        echo -e "  ${BOLD}Useful commands:${NC}"
        echo -e "    cat ~/Library/Logs/open-terminal/stdout.log"
        [ "$AUTO_UPDATE" = true ] && echo -e "    cat ~/Library/Logs/open-terminal/update.log"
    fi

    echo ""
    echo -e "  ${BOLD}Tip:${NC} Re-run this script to reconfigure, update, or uninstall."
    echo ""
}

# --- Main ---
main() {
    banner
    detect_os
    check_root

    if is_installed; then
        management_menu
    else
        fresh_install
    fi
}

main "$@"
