#!/bin/bash

set -e

ISO_NAME="ubuntu-24.04-kiosk-docker"
WORK_DIR="/home/ubuntu/custom-iso"
CACHE_DIR="/home/ubuntu/iso-cache"
SOURCE_ISO="/home/ubuntu/Downloads/ubuntu-24.04.3-live-server-amd64.iso"

# Kiosk settings
KIOSK_URL="http://127.0.0.1:8090"  # Default to Docker app, fallback to nginx on port 80
DEFAULT_URL="http://127.0.0.1:80"
KIOSK_USER="kiosk"
KIOSK_PASS="kiosk"
DOCKER_IMAGE="bomeravi/go-app-test"
DOCKER_PORT="8090"
KIOSK_MODE="terminal"  # Options: "chrome" or "terminal"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }

check_root() {
    [ "$EUID" -eq 0 ] || error "Please run with sudo"
}

install_deps() {
    log "Installing dependencies..."
    apt update
    apt install -y \
        xorriso squashfs-tools genisoimage p7zip-full \
        wget mtools dosfstools grub-efi-amd64-bin \
        grub-pc-bin debootstrap rsync grub-common \
        grub2-common isolinux syslinux-common apt-cacher-ng 2>/dev/null || true
}

setup_cache() {
    log "Setting up package cache..."
    
    mkdir -p "$CACHE_DIR"/{debootstrap,apt-archives,chrome,docker}
    
    # Check if we have cached debootstrap
    if [ -d "$CACHE_DIR/debootstrap/var/cache/apt/archives" ]; then
        CACHED_DEBS=$(ls "$CACHE_DIR/debootstrap/var/cache/apt/archives/"*.deb 2>/dev/null | wc -l)
        info "Found $CACHED_DEBS cached debootstrap packages"
    fi
    
    # Check for cached apt packages
    if [ -d "$CACHE_DIR/apt-archives" ]; then
        CACHED_APT=$(ls "$CACHE_DIR/apt-archives/"*.deb 2>/dev/null | wc -l)
        info "Found $CACHED_APT cached apt packages"
    fi
    
    # Check for cached Chrome
    if [ -f "$CACHE_DIR/chrome/google-chrome-stable_current_amd64.deb" ]; then
        info "Found cached Chrome installer"
    fi
    
    # Check for cached Docker image
    if [ -f "$CACHE_DIR/docker/${DOCKER_IMAGE//\//_}.tar" ]; then
        info "Found cached Docker image"
    fi
}

cleanup_mounts() {
    log "Cleaning up mounts..."
    cd /
    for mount_point in run sys proc dev/pts dev; do
        umount -lf "$WORK_DIR/filesystem/$mount_point" 2>/dev/null || true
    done
    umount -lf "$WORK_DIR/mnt" 2>/dev/null || true
    umount -lf "$WORK_DIR/efi_mount" 2>/dev/null || true
}

setup_dirs() {
    log "Setting up directories..."
    
    if [ -d "$WORK_DIR" ]; then
        warn "Cleaning up previous build..."
        cleanup_mounts
        rm -rf "$WORK_DIR"
    fi
    
    mkdir -p "$WORK_DIR"/{mnt,extract,filesystem,efi_mount}
}

extract_iso_structure() {
    log "Extracting ISO boot structure..."
    
    mount -o loop "$SOURCE_ISO" "$WORK_DIR/mnt"
    
    rsync -a --exclude='*.squashfs' "$WORK_DIR/mnt/" "$WORK_DIR/extract/"
    
    if [ -f "$WORK_DIR/mnt/boot/grub/efi.img" ]; then
        log "Found existing EFI image"
        cp "$WORK_DIR/mnt/boot/grub/efi.img" "$WORK_DIR/extract/boot/grub/"
    fi
    
    chmod -R u+w "$WORK_DIR/extract/"
    find "$WORK_DIR/extract" -xtype l -delete 2>/dev/null || true
    
    umount "$WORK_DIR/mnt"
    
    mkdir -p "$WORK_DIR/extract/casper"
    mkdir -p "$WORK_DIR/extract/boot/grub/i386-pc"
    mkdir -p "$WORK_DIR/extract/EFI/BOOT"
    mkdir -p "$WORK_DIR/extract/isolinux"
    
    if [ ! -f "$WORK_DIR/extract/boot/grub/i386-pc/eltorito.img" ]; then
        log "Creating BIOS boot image (eltorito.img)..."
        grub-mkimage -O i386-pc-eltorito \
            -o "$WORK_DIR/extract/boot/grub/i386-pc/eltorito.img" \
            -p /boot/grub \
            biosdisk iso9660 normal search search_label search_fs_file \
            configfile linux linux16 loopback chain fat ext2 \
            part_msdos part_gpt all_video || warn "Could not create eltorito.img"
    fi
    
    if [ -f /usr/lib/ISOLINUX/isolinux.bin ]; then
        cp /usr/lib/ISOLINUX/isolinux.bin "$WORK_DIR/extract/isolinux/" 2>/dev/null || true
        cp /usr/lib/syslinux/modules/bios/*.c32 "$WORK_DIR/extract/isolinux/" 2>/dev/null || true
    fi
    
    log "ISO structure extracted"
}

create_efi_image() {
    log "Creating EFI boot image..."
    
    EFI_IMG="$WORK_DIR/efi.img"
    EFI_SIZE=16
    
    dd if=/dev/zero of="$EFI_IMG" bs=1M count=$EFI_SIZE status=progress
    mkfs.vfat -F 16 "$EFI_IMG"
    
    mount -o loop "$EFI_IMG" "$WORK_DIR/efi_mount"
    
    mkdir -p "$WORK_DIR/efi_mount/EFI/BOOT"
    mkdir -p "$WORK_DIR/efi_mount/boot/grub"
    
    if [ -f "$WORK_DIR/extract/EFI/BOOT/BOOTX64.EFI" ]; then
        cp "$WORK_DIR/extract/EFI/BOOT/"* "$WORK_DIR/efi_mount/EFI/BOOT/" 2>/dev/null || true
    elif [ -f "$WORK_DIR/extract/EFI/boot/bootx64.efi" ]; then
        cp "$WORK_DIR/extract/EFI/boot/"* "$WORK_DIR/efi_mount/EFI/BOOT/" 2>/dev/null || true
    else
        log "Generating GRUB EFI bootloader..."
        grub-mkimage -O x86_64-efi \
            -o "$WORK_DIR/efi_mount/EFI/BOOT/BOOTX64.EFI" \
            -p /boot/grub \
            part_gpt part_msdos fat iso9660 udf normal boot linux configfile \
            loopback chain efifwsetup efi_gop efi_uga ls search \
            search_label search_fs_uuid search_fs_file test all_video \
            loadenv exfat ext2 ntfs hfsplus || warn "grub-mkimage failed"
    fi
    
    cat > "$WORK_DIR/efi_mount/boot/grub/grub.cfg" << 'GRUB'
search --set=root --file /casper/vmlinuz
set prefix=($root)/boot/grub
configfile $prefix/grub.cfg
GRUB
    
    mkdir -p "$WORK_DIR/efi_mount/EFI/BOOT/grub"
    cp "$WORK_DIR/efi_mount/boot/grub/grub.cfg" "$WORK_DIR/efi_mount/EFI/BOOT/grub/" 2>/dev/null || true
    # Also copy to the main EFI/BOOT directory which is where the shim/loader often looks first
    cp "$WORK_DIR/efi_mount/boot/grub/grub.cfg" "$WORK_DIR/efi_mount/EFI/BOOT/grub.cfg" 2>/dev/null || true
    
    sync
    umount "$WORK_DIR/efi_mount"
    
    log "EFI image created: $(du -h "$EFI_IMG" | cut -f1)"
}

create_base_system() {
    log "Creating base Ubuntu 24.04 system with debootstrap..."
    
    # Check for cached debootstrap
    if [ -f "$CACHE_DIR/base-system.tar.gz" ]; then
        info "Using cached base system (saves ~5 minutes)..."
        tar -xzf "$CACHE_DIR/base-system.tar.gz" -C "$WORK_DIR/filesystem"
        log "Base system restored from cache"
        return 0
    fi
    
    log "Downloading base system (this will be cached for future builds)..."
    
    debootstrap \
        --arch=amd64 \
        --variant=minbase \
        --components=main,restricted,universe,multiverse \
        --include=systemd,systemd-sysv,sudo,locales,apt-utils \
        noble \
        "$WORK_DIR/filesystem" \
        http://archive.ubuntu.com/ubuntu
    
    if [ ! -f "$WORK_DIR/filesystem/bin/bash" ] && [ ! -f "$WORK_DIR/filesystem/usr/bin/bash" ]; then
        error "Debootstrap failed - bash not found"
    fi
    
    # Cache the base system for future builds
    log "Caching base system for future builds..."
    tar -czf "$CACHE_DIR/base-system.tar.gz" -C "$WORK_DIR/filesystem" .
    info "Base system cached: $(du -h "$CACHE_DIR/base-system.tar.gz" | cut -f1)"
    
    log "Base system created successfully"
}

mount_chroot() {
    mount --bind /dev "$WORK_DIR/filesystem/dev"
    mount --bind /dev/pts "$WORK_DIR/filesystem/dev/pts"
    mount -t proc proc "$WORK_DIR/filesystem/proc"
    mount -t sysfs sysfs "$WORK_DIR/filesystem/sys"
    mount --bind /run "$WORK_DIR/filesystem/run"
    
    cp /etc/resolv.conf "$WORK_DIR/filesystem/etc/resolv.conf"
}

unmount_chroot() {
    cd /
    sync
    sleep 1
    
    umount -l "$WORK_DIR/filesystem/run" 2>/dev/null || true
    umount -l "$WORK_DIR/filesystem/sys" 2>/dev/null || true
    umount -l "$WORK_DIR/filesystem/proc" 2>/dev/null || true
    umount -l "$WORK_DIR/filesystem/dev/pts" 2>/dev/null || true
    umount -l "$WORK_DIR/filesystem/dev" 2>/dev/null || true
}

download_chrome() {
    log "Downloading Chrome..."
    
    CHROME_DEB="$CACHE_DIR/chrome/google-chrome-stable_current_amd64.deb"
    
    # Download Chrome if not cached or older than 7 days
    if [ ! -f "$CHROME_DEB" ] || [ $(find "$CHROME_DEB" -mtime +7 2>/dev/null | wc -l) -gt 0 ]; then
        info "Downloading fresh Chrome package..."
        wget -q --show-progress -O "$CHROME_DEB" \
            "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
        info "Chrome cached: $(du -h "$CHROME_DEB" | cut -f1)"
    else
        info "Using cached Chrome package"
    fi
    
    # Copy to filesystem
    cp "$CHROME_DEB" "$WORK_DIR/filesystem/tmp/"
}

download_docker_image() {
    log "Preparing Docker image..."
    
    DOCKER_TAR="$CACHE_DIR/docker/${DOCKER_IMAGE//\//_}.tar"
    
    # Check if image is cached
    if [ -f "$DOCKER_TAR" ]; then
        info "Using cached Docker image"
        cp "$DOCKER_TAR" "$WORK_DIR/filesystem/tmp/docker-image.tar"
    else
        info "Docker image not in cache, pulling..."
        if docker pull "$DOCKER_IMAGE"; then
            info "Saving Docker image to cache..."
            docker save -o "$DOCKER_TAR" "$DOCKER_IMAGE"
            cp "$DOCKER_TAR" "$WORK_DIR/filesystem/tmp/docker-image.tar"
            info "Docker image saved to cache: $(du -h "$DOCKER_TAR" | cut -f1)"
        else
            warn "Failed to pull Docker image! It will be pulled during first boot (internet required)."
        fi
    fi
}

configure_system() {
    log "Configuring system inside chroot..."
    
    # Download Chrome first (outside chroot for caching)
    download_chrome
    download_docker_image
    
    # Restore cached apt packages if available
    if [ -d "$CACHE_DIR/apt-archives" ] && [ "$(ls -A $CACHE_DIR/apt-archives/*.deb 2>/dev/null)" ]; then
        info "Restoring cached apt packages..."
        mkdir -p "$WORK_DIR/filesystem/var/cache/apt/archives"
        cp "$CACHE_DIR/apt-archives/"*.deb "$WORK_DIR/filesystem/var/cache/apt/archives/" 2>/dev/null || true
    fi
    
    cat > "$WORK_DIR/filesystem/tmp/setup.sh" << 'SETUP_SCRIPT'
#!/bin/bash
set -e

export HOME=/root
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

echo "=== Starting system setup ==="

# Configure apt sources
cat > /etc/apt/sources.list << 'APT'
deb http://archive.ubuntu.com/ubuntu noble main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu noble-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu noble-security main restricted universe multiverse
APT

# Keep downloaded packages for caching
cat > /etc/apt/apt.conf.d/99keep-cache << 'APTCONF'
Binary::apt::APT::Keep-Downloaded-Packages "true";
APTCONF

echo "Updating package lists..."
apt update

echo "Installing kernel and boot packages..."
apt install -y linux-generic linux-headers-generic

echo "Installing essential packages..."
apt install -y \
    ubuntu-minimal \
    network-manager \
    openssh-server \
    casper \
    discover \
    laptop-detect \
    os-prober \
    init \
    curl \
    ca-certificates \
    gnupg \
    lsb-release \
    vim \
    nano \
    parted \
    rsync \
    dosfstools \
    iputils-ping \
    grub-common \
    grub2-common \
    grub-pc-bin \
    grub-efi-amd64-bin \
    grub-efi-amd64-signed \
    shim-signed \
    efibootmgr \
    netplan.io \
    procps \
    psmisc

echo "Installing Docker..."
# Install Docker from official repository
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "Installing X11 and display components..."
apt install -y --no-install-recommends \
    xorg \
    xserver-xorg \
    xserver-xorg-video-all \
    xserver-xorg-input-all \
    openbox \
    lightdm \
    lightdm-gtk-greeter \
    unclutter-xfixes \
    x11-xserver-utils \
    x11-utils \
    dbus-x11 \
    libnotify-bin \
    pulseaudio \
    alsa-utils \
    xterm

echo "Installing nginx..."
apt install -y nginx

echo "Installing Chrome dependencies (Ubuntu 24.04 t64 packages)..."
apt install -y \
    wget \
    fonts-liberation \
    fonts-noto-color-emoji \
    xdg-utils \
    libnss3 \
    libatk-bridge2.0-0t64 \
    libgtk-3-0t64 \
    libgbm1 \
    libasound2t64 \
    libxss1 \
    libappindicator3-1 \
    libsecret-1-0

echo "Installing Chrome from cached .deb..."
if [ -f /tmp/google-chrome-stable_current_amd64.deb ]; then
    dpkg -i /tmp/google-chrome-stable_current_amd64.deb || true
    apt install -f -y
    rm /tmp/google-chrome-stable_current_amd64.deb
else
    echo "Chrome .deb not found, downloading..."
    wget -q -O /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
    dpkg -i /tmp/chrome.deb || true
    apt install -f -y
    rm /tmp/chrome.deb
fi

# Verify Chrome installed
if ! command -v google-chrome-stable &> /dev/null; then
    echo "ERROR: Chrome installation failed!"
    exit 1
fi
echo "Chrome installed successfully: $(google-chrome-stable --version)"

echo "Creating kiosk user..."
useradd -m -s /bin/bash -G audio,video,sudo,plugdev,netdev,docker kiosk
echo "kiosk:kiosk" | chpasswd

# Allow kiosk user passwordless sudo for specific commands
echo "kiosk ALL=(ALL) NOPASSWD: /sbin/reboot, /sbin/shutdown" > /etc/sudoers.d/kiosk
chmod 440 /etc/sudoers.d/kiosk

echo "Configuring SSH for LAN access..."
# Enable SSH password authentication
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config

# Allow root login (optional, uncomment if needed)
# sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config

# Ensure SSH listens on all interfaces
echo "ListenAddress 0.0.0.0" >> /etc/ssh/sshd_config

echo "Enabling services..."
systemctl enable lightdm
systemctl enable docker
systemctl enable NetworkManager
systemctl enable ssh
systemctl enable nginx

# Configure NetworkManager to manage all interfaces
cat > /etc/NetworkManager/NetworkManager.conf << 'NMCONF'
[main]
plugins=ifupdown,keyfile
dns=default

[ifupdown]
managed=true

[device]
wifi.scan-rand-mac-address=no
NMCONF

# Create netplan configuration for NetworkManager
mkdir -p /etc/netplan
cat > /etc/netplan/01-network-manager-all.yaml << 'NETPLAN'
# Let NetworkManager manage all devices on this system
network:
  version: 2
  renderer: NetworkManager
NETPLAN

chmod 600 /etc/netplan/01-network-manager-all.yaml

# Disable unnecessary services for faster boot
systemctl disable apt-daily.timer 2>/dev/null || true
systemctl disable apt-daily-upgrade.timer 2>/dev/null || true
systemctl disable snapd.service 2>/dev/null || true
systemctl disable snapd.socket 2>/dev/null || true
systemctl disable ModemManager.service 2>/dev/null || true

echo "Setting up locale..."
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8

echo "Configuring hostname..."
echo "kiosk" > /etc/hostname
cat > /etc/hosts << 'HOSTS'
127.0.0.1   localhost
127.0.1.1   kiosk
HOSTS

# Load Docker image if cached
if [ -f /tmp/docker-image.tar ]; then
    echo "Loading cached Docker image..."
    docker load -i /tmp/docker-image.tar || true
    rm /tmp/docker-image.tar
fi

echo "=== Setup complete! ==="
SETUP_SCRIPT

    chmod +x "$WORK_DIR/filesystem/tmp/setup.sh"
    
    mount_chroot
    
    log "Running setup script in chroot..."
    chroot "$WORK_DIR/filesystem" /bin/bash /tmp/setup.sh
    
    # Cache apt packages for future builds
    log "Caching apt packages for future builds..."
    mkdir -p "$CACHE_DIR/apt-archives"
    cp "$WORK_DIR/filesystem/var/cache/apt/archives/"*.deb "$CACHE_DIR/apt-archives/" 2>/dev/null || true
    CACHED_COUNT=$(ls "$CACHE_DIR/apt-archives/"*.deb 2>/dev/null | wc -l)
    info "Cached $CACHED_COUNT packages for future builds"
    
    # Clean apt cache in filesystem to reduce ISO size
    chroot "$WORK_DIR/filesystem" apt clean
    
    unmount_chroot
}

create_kiosk_configs() {
    log "Creating kiosk configuration files..."
    
    #############################################
    # 0. Nginx web page (served on port 80)
    #############################################
    mkdir -p "$WORK_DIR/filesystem/var/www/html"
    cat > "$WORK_DIR/filesystem/var/www/html/index.html" << 'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Kiosk System</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Segoe UI', sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            display: flex;
            justify-content: center;
            align-items: center;
            color: white;
        }
        .container {
            text-align: center;
            padding: 40px;
            background: rgba(255,255,255,0.1);
            border-radius: 20px;
            backdrop-filter: blur(10px);
        }
        h1 { font-size: 3rem; margin-bottom: 20px; }
        .status {
            margin-top: 30px;
            padding: 15px 30px;
            background: rgba(76,175,80,0.3);
            border-radius: 10px;
            border: 2px solid #4CAF50;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>🖥️ Kiosk System</h1>
        <p>Welcome to the system, the application is loading...</p>
        <div class="status">✓ System Online</div>
    </div>
</body>
</html>
HTML

    #############################################
    # 1. Docker startup service
    #############################################
    mkdir -p "$WORK_DIR/filesystem/etc/systemd/system"
    cat > "$WORK_DIR/filesystem/etc/systemd/system/docker-app.service" << DOCKERSERVICE
[Unit]
Description=Docker App Container
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
User=kiosk
Restart=always
RestartSec=10
ExecStartPre=/bin/bash -c 'for i in {1..30}; do docker info && break || sleep 2; done'
ExecStartPre=-/usr/bin/docker stop go-app-container
ExecStartPre=-/usr/bin/docker rm go-app-container
ExecStartPre=/usr/bin/docker pull ${DOCKER_IMAGE}
ExecStart=/usr/bin/docker run --rm --name go-app-container -p ${DOCKER_PORT}:${DOCKER_PORT} ${DOCKER_IMAGE}
ExecStop=/usr/bin/docker stop go-app-container

[Install]
WantedBy=multi-user.target
DOCKERSERVICE

    #############################################
    # 2. Network info display service (shows IP on tty2)
    #############################################
    cat > "$WORK_DIR/filesystem/usr/local/bin/show-network-info.sh" << 'NETINFO'
#!/bin/bash
while true; do
    clear > /dev/tty2
    echo "=====================================" > /dev/tty2
    echo "   KIOSK SYSTEM - NETWORK INFO" > /dev/tty2
    echo "=====================================" > /dev/tty2
    echo "" > /dev/tty2
    echo "Hostname: $(hostname)" > /dev/tty2
    echo "" > /dev/tty2
    echo "Network Interfaces:" > /dev/tty2
    ip -4 addr show | grep -E "^\s*inet " | grep -v "127.0.0.1" | awk '{print "  " $NF ": " $2}' > /dev/tty2
    echo "" > /dev/tty2
    echo "SSH Access:" > /dev/tty2
    echo "  ssh kiosk@<IP_ADDRESS>" > /dev/tty2
    echo "  Password: kiosk" > /dev/tty2
    echo "" > /dev/tty2
    echo "Docker Container:" > /dev/tty2
    docker ps --format "  {{.Names}}: {{.Status}}" 2>/dev/null > /dev/tty2
    echo "" > /dev/tty2
    echo "Press Ctrl+Alt+F1 to return to kiosk" > /dev/tty2
    echo "Press Ctrl+Alt+F2 to view this info" > /dev/tty2
    echo "" > /dev/tty2
    echo "Last updated: $(date)" > /dev/tty2
    echo "=====================================" > /dev/tty2
    sleep 10
done
NETINFO
    chmod +x "$WORK_DIR/filesystem/usr/local/bin/show-network-info.sh"

    cat > "$WORK_DIR/filesystem/etc/systemd/system/network-info.service" << 'NETINFOSERVICE'
[Unit]
Description=Network Info Display on TTY2
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/show-network-info.sh
Restart=always
StandardOutput=tty
StandardError=tty
TTYPath=/dev/tty2

[Install]
WantedBy=multi-user.target
NETINFOSERVICE

    # Enable the services
    mount_chroot
    chroot "$WORK_DIR/filesystem" systemctl enable docker-app.service
    chroot "$WORK_DIR/filesystem" systemctl enable network-info.service
    unmount_chroot

    #############################################
    # 2. LightDM Auto-login Configuration
    #############################################
    mkdir -p "$WORK_DIR/filesystem/etc/lightdm/lightdm.conf.d"
    
    # Main LightDM config for AUTO-LOGIN
    cat > "$WORK_DIR/filesystem/etc/lightdm/lightdm.conf" << 'LIGHTDM'
[LightDM]
logind-check-graphical=false
run-directory=/run/lightdm

[Seat:*]
autologin-guest=false
autologin-user=kiosk
autologin-user-timeout=0
autologin-session=openbox
user-session=openbox
greeter-session=lightdm-gtk-greeter
xserver-command=X -s 0 -dpms -nocursor
LIGHTDM

    # Autologin override config
    cat > "$WORK_DIR/filesystem/etc/lightdm/lightdm.conf.d/50-autologin.conf" << 'AUTOLOGIN'
[Seat:*]
autologin-guest=false
autologin-user=kiosk
autologin-user-timeout=0
autologin-session=openbox
user-session=openbox
AUTOLOGIN

    # Disable guest
    cat > "$WORK_DIR/filesystem/etc/lightdm/lightdm.conf.d/50-no-guest.conf" << 'NOGUEST'
[Seat:*]
allow-guest=false
NOGUEST

    # PAM configuration for autologin
    cat > "$WORK_DIR/filesystem/etc/pam.d/lightdm-autologin" << 'PAM'
auth        requisite       pam_nologin.so
auth        required        pam_succeed_if.so user != root quiet_success
auth        required        pam_permit.so
@include common-account
session     required        pam_loginuid.so
session     required        pam_limits.so
@include common-session
@include common-password
PAM

    #############################################
    # 3. Openbox Window Manager Configuration
    #############################################
    mkdir -p "$WORK_DIR/filesystem/home/kiosk/.config/openbox"
    
    
    # Openbox autostart - MAIN KIOSK SCRIPT with mode detection
    # Step 1: Inject variables
    cat > "$WORK_DIR/filesystem/home/kiosk/.config/openbox/autostart" << EOF
#!/bin/bash
KIOSK_URL="${KIOSK_URL}"
DEFAULT_URL="${DEFAULT_URL}"
EOF

    # Step 2: Append script using variables
    cat >> "$WORK_DIR/filesystem/home/kiosk/.config/openbox/autostart" << 'AUTOSTART'

# Log for debugging
exec >> /home/kiosk/kiosk.log 2>&1
echo "=== Kiosk starting at $(date) ==="

# VISUAL FEEDBACK: Set background to blue immediately to prove X is running
xsetroot -solid "#224488"
xsetroot -cursor_name left_ptr

    # Loading screen removed as per user request

# Read kiosk mode from kernel command line or config file
# Default logic based on installation state
if grep -q "^UUID=" /etc/fstab 2>/dev/null; then
    # Installed on hard disk -> Default to Chrome
    KIOSK_MODE="chrome"
else
    # Live session -> Default to Terminal (for installation)
    KIOSK_MODE="terminal"
fi

# Allow kernel command line overrides
if grep -q "kiosk_mode=terminal" /proc/cmdline; then
    KIOSK_MODE="terminal"
elif grep -q "kiosk_mode=chrome" /proc/cmdline; then
    KIOSK_MODE="chrome"
fi

# Check config file (can override at runtime)
if [ -f /etc/kiosk-mode.conf ]; then
    source /etc/kiosk-mode.conf
fi

echo "Kiosk mode: $KIOSK_MODE"

# Wait for X to be ready
sleep 2

if [ "$KIOSK_MODE" = "terminal" ]; then
    echo "=== Starting TERMINAL MODE ==="
    
    # Disable screen blanking
    xset s off
    xset s noblank
    xset -dpms
    xset s 0 0
    
    # Wait for Docker app
    echo "Waiting for Docker app..."
    for i in {1..60}; do
        if curl -s ${KIOSK_URL} > /dev/null 2>&1; then
            echo "Docker app is ready"
            break
        fi
        sleep 2
    done
    
    # Launch terminal with system info
    xterm -maximized -fullscreen \
        -fa 'Monospace' -fs 14 \
        -bg black -fg green \
        -title "Kiosk Terminal" \
        -e /usr/local/bin/kiosk-terminal.sh &
    
    echo "Terminal mode started"
    
else
    echo "=== Starting CHROME FULLSCREEN MODE ==="
    
    # Disable screen blanking and power management
    xset s off
    xset s noblank
    xset -dpms
    xset s 0 0

    # Hide cursor after 0.5 seconds
    unclutter-xfixes --timeout 0.5 --jitter 2 --hide-on-touch &

    # Show loading screen - REMOVED
    # xterm -geometry 80x20+0+0 -bg blue -fg white -title "System Loading" -e bash -c "echo ' '; echo '   KIOSK SYSTEM LOADING...'; echo ' '; echo '   Waiting for Docker application...'; echo ' '; while true; do sleep 1; done" &
    # LOADING_PID=$!
    
    # Wait for Docker app to be ready (or fallback to nginx)
    # Wait for Docker to be ready (simplified - main loop handles fallback)
    # We moved the logic to the main loop to allow immediate Nginx display
    echo "Checking Docker status..."
    
    # Kill loading screen - REMOVED
    # kill $LOADING_PID 2>/dev/null
    
    echo "Opening kiosk to: $APP_URL"

    # Clean Chrome profile
    # Singleton lock cleaned up inside the loop now
    mkdir -p /home/kiosk/.config/google-chrome/Default

    # Chrome preferences
    cat > /home/kiosk/.config/google-chrome/Default/Preferences << 'PREFS'
{
    "browser": {"check_default_browser": false},
    "credentials_enable_service": false,
    "profile": {"password_manager_enabled": false}
}
PREFS

    touch "/home/kiosk/.config/google-chrome/First Run"

    echo "Starting Chrome kiosk at $(date)..."

    # Chrome FULL KIOSK mode
    # Variable to track monitor PID
    MONITOR_PID=""

    # Chrome FULL KIOSK mode
    while true; do
        # Clean up any lock files from previous crashes to prevent immediate exit
        rm -rf /home/kiosk/.config/google-chrome/Singleton* 2>/dev/null

        # DYNAMIC URL SELECTION
        # Check if Docker app is ready
        if curl -s ${KIOSK_URL} > /dev/null; then
            echo "Docker is UP. Launching main app."
            APP_URL="${KIOSK_URL}"
            
            # Kill monitor if running (we are in the desired state)
            if [ -n "$MONITOR_PID" ]; then
                kill $MONITOR_PID 2>/dev/null || true
                MONITOR_PID=""
            fi
        else
            echo "Docker is DOWN. Launching Nginx fallback."
            APP_URL="${DEFAULT_URL}"
            
            # Start background monitor to kill Chrome when Docker comes up
            # Only start if not already running
            if [ -z "$MONITOR_PID" ] || ! kill -0 $MONITOR_PID 2>/dev/null; then
                (
                    echo "Monitor $(date): Waiting for Docker on port 8090..."
                    # Debug: Show status of all containers
                    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" || echo "Monitor: Error listing containers (permission denied?)"
                    
                    # Verbose curl to see exactly why it fails (refused? timeout?)
                    until curl -v ${KIOSK_URL} > /dev/null 2>&1; do
                        sleep 1
                    done
                    
                    echo "Monitor $(date): Docker is UP! Killing Chrome to trigger reload..."
                    
                    # Debug: show processes before kill
                    ps aux | grep chrome || echo "Monitor: No chrome found in ps?"

                    # Aggressive Kill Loop: Keep killing until it's dead
                    MAX_TRIES=10
                    count=0
                    while pgrep -f "chrome" > /dev/null && [ $count -lt $MAX_TRIES ]; do
                         echo "Monitor: Sending kill signal (attempt $((count+1)))..."
                         pkill -f "chrome" || true
                         killall google-chrome-stable 2>/dev/null || true
                         sleep 1
                         count=$((count+1))
                    done
                    
                    if pgrep -f "chrome" > /dev/null; then
                        echo "Monitor: WARNING - Chrome still running after kill attempts. Using SIGKILL."
                        pkill -9 -f "chrome" || true
                    else
                        echo "Monitor: Chrome process terminated successfully."
                    fi
                ) &
                
                MONITOR_PID=$!
                echo "Monitor started with PID $MONITOR_PID"
            fi
        fi

        echo "Launching Chrome with URL: $APP_URL"
        google-chrome-stable \
            --kiosk \
            --no-sandbox \
            --disable-gpu \
            --disable-dev-shm-usage \
            --no-first-run \
            --no-default-browser-check \
            --disable-infobars \
            --disable-translate \
            --disable-features=TranslateUI \
            --app="$APP_URL" > /home/kiosk/chrome.log 2>&1
        
        EXIT_CODE=$?
        echo "Chrome exited with code $EXIT_CODE at $(date), restarting in 2s..." >> /home/kiosk/chrome.log
        
        # If we are restarting, check if it was due to our monitor
        # If so, the loop will catch the new URL on next iteration
        sleep 2
    done
fi
# Kill loading window if still running - REMOVED
# kill $LOADING_PID 2>/dev/null || true
AUTOSTART

    chmod +x "$WORK_DIR/filesystem/home/kiosk/.config/openbox/autostart"

    # Openbox rc.xml - minimal config, no decorations
    # Step 1: Inject variables
    cat > "$WORK_DIR/filesystem/usr/local/bin/kiosk-terminal.sh" << EOF
#!/bin/bash
KIOSK_URL="${KIOSK_URL}"
DEFAULT_URL="${DEFAULT_URL}"
EOF

    # Step 2: Append script using variables
    cat >> "$WORK_DIR/filesystem/usr/local/bin/kiosk-terminal.sh" << 'TERMSCRIPT'

clear

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

show_header() {
    clear
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}          ${CYAN}KIOSK SYSTEM - TERMINAL MODE${NC}               ${GREEN}║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

show_info() {
    echo -e "${YELLOW}═══ SYSTEM INFORMATION ═══${NC}"
    echo -e "${BLUE}Hostname:${NC} $(hostname)"
    echo -e "${BLUE}Uptime:${NC} $(uptime -p)"
    echo ""
    
    echo -e "${YELLOW}═══ NETWORK ═══${NC}"
    ip -4 addr show | grep -E "^\s*inet " | grep -v "127.0.0.1" | while read line; do
        IP=$(echo $line | awk '{print $2}')
        IFACE=$(echo $line | awk '{print $NF}')
        echo -e "${BLUE}$IFACE:${NC} $IP"
    done
    echo ""
    
    echo -e "${YELLOW}═══ DOCKER CONTAINER ═══${NC}"
    if docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null | tail -n +2; then
        echo ""
    else
        echo "No containers running"
        echo ""
    fi
    
    echo -e "${YELLOW}═══ APPLICATION STATUS ═══${NC}"
    
    # Check Docker app
    if curl -s ${KIOSK_URL} > /dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} Docker App: ${KIOSK_URL}"
    else
        echo -e "${YELLOW}⚠${NC} Docker App: Not responding"
    fi
    
    # Check nginx
    if curl -s ${DEFAULT_URL} > /dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} Nginx: ${DEFAULT_URL}"
    else
        echo -e "${YELLOW}⚠${NC} Nginx: Not responding"
    fi
    
    echo ""
}

show_menu() {
    echo -e "${YELLOW}═══ QUICK COMMANDS ═══${NC}"
    
    # Check if running from live session
    if ! grep -q "^UUID=" /etc/fstab 2>/dev/null; then
        echo -e "  ${CYAN}0.${NC} ${GREEN}Install to Hard Disk (RECOMMENDED)${NC}"
    fi
    
    echo -e "  ${CYAN}1.${NC} View app in browser (local)"
    echo -e "  ${CYAN}2.${NC} Restart Docker container"
    echo -e "  ${CYAN}3.${NC} View Docker logs"
    echo -e "  ${CYAN}4.${NC} View kiosk logs"
    echo -e "  ${CYAN}5.${NC} Switch to Chrome kiosk mode (reboot required)"
    echo -e "  ${CYAN}6.${NC} Network diagnostics"
    echo -e "  ${CYAN}7.${NC} System shell"
    echo -e "  ${CYAN}r.${NC} Refresh info"
    echo -e "  ${CYAN}q.${NC} Reboot system"
    echo ""
    echo -n "Enter choice: "
}

while true; do
    show_header
    show_info
    show_menu
    
    read -t 30 -n 1 choice
    echo ""
    
    case $choice in
        0)
            echo "Starting hard disk installer..."
            sudo /usr/local/bin/install-to-disk.sh
            ;;
        1)
            echo "Opening browser..."
            google-chrome-stable ${KIOSK_URL} &
            sleep 3
            ;;
        2)
            echo "Restarting Docker container..."
            docker restart go-app-container
            sleep 2
            ;;
        3)
            echo "Docker logs (press Ctrl+C to return):"
            docker logs -f --tail 50 go-app-container
            ;;
        4)
            echo "Kiosk logs (press Ctrl+C to return):"
            tail -f /home/kiosk/kiosk.log
            ;;
        5)
            echo "Switching to Chrome kiosk mode..."
            echo 'KIOSK_MODE="chrome"' | sudo tee /etc/kiosk-mode.conf
            echo "Mode changed. Rebooting in 3 seconds..."
            sleep 3
            sudo reboot
            ;;
        6)
            clear
            echo -e "${YELLOW}═══ NETWORK DIAGNOSTICS ═══${NC}"
            echo ""
            echo "IP Configuration:"
            ip addr show
            echo ""
            echo "Routing Table:"
            ip route
            echo ""
            echo "DNS Configuration:"
            cat /etc/resolv.conf
            echo ""
            echo "Network Manager Status:"
            nmcli general status
            echo ""
            echo "Active Connections:"
            nmcli connection show --active
            echo ""
            echo "Internet Connectivity Test:"
            if ping -c 2 8.8.8.8 &> /dev/null; then
                echo -e "${GREEN}✓ Internet connectivity working${NC}"
            else
                echo -e "${RED}✗ No internet connectivity${NC}"
                echo ""
                echo "Troubleshooting tips:"
                echo "  1. Check if NetworkManager is running:"
                echo "     sudo systemctl status NetworkManager"
                echo ""
                echo "  2. Restart NetworkManager:"
                echo "     sudo systemctl restart NetworkManager"
                echo ""
                echo "  3. Check netplan config:"
                echo "     cat /etc/netplan/*.yaml"
                echo ""
                echo "  4. Apply netplan:"
                echo "     sudo netplan apply"
            fi
            echo ""
            echo "Press Enter to continue..."
            read
            ;;
        7)
            echo "Starting shell (type 'exit' to return)..."
            bash
            ;;
        r|R|"")
            # Just refresh (timeout or explicit refresh)
            continue
            ;;
        q|Q)
            echo "Rebooting system..."
            sudo reboot
            ;;
        *)
            echo "Invalid choice"
            sleep 1
            ;;
    esac
done
TERMSCRIPT

    chmod +x "$WORK_DIR/filesystem/usr/local/bin/kiosk-terminal.sh"

    # Openbox rc.xml - minimal config, no decorations
    cat > "$WORK_DIR/filesystem/home/kiosk/.config/openbox/rc.xml" << 'RCXML'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <resistance><strength>10</strength><screen_edge_strength>20</screen_edge_strength></resistance>
  <focus><focusNew>yes</focusNew><followMouse>no</followMouse></focus>
  <placement><policy>Smart</policy><center>yes</center></placement>
  <theme><name>Clearlooks</name><keepBorder>no</keepBorder></theme>
  <desktops><number>1</number><popupTime>0</popupTime></desktops>
  <keyboard>
    <keybind key="C-A-t">
      <action name="Execute">
        <command>xterm -maximized -fullscreen -fa 'Monospace' -fs 14 -bg black -fg green -title "Kiosk Terminal" -e /usr/local/bin/kiosk-terminal.sh</command>
      </action>
    </keybind>
  </keyboard>
  <mouse></mouse>
  <applications>
    <application class="*">
      <decor>no</decor>
      <fullscreen>yes</fullscreen>
      <maximized>yes</maximized>
    </application>
  </applications>
</openbox_config>
RCXML

    # Openbox environment
    cat > "$WORK_DIR/filesystem/home/kiosk/.config/openbox/environment" << 'ENV'
export DISPLAY=:0
export XDG_SESSION_TYPE=x11
ENV

    #############################################
    # 4. Session files
    #############################################
    cat > "$WORK_DIR/filesystem/home/kiosk/.xsession" << 'XSESSION'
#!/bin/bash
exec openbox-session
XSESSION
    chmod +x "$WORK_DIR/filesystem/home/kiosk/.xsession"
    
    cat > "$WORK_DIR/filesystem/home/kiosk/.xinitrc" << 'XINITRC'
#!/bin/bash
exec openbox-session
XINITRC
    chmod +x "$WORK_DIR/filesystem/home/kiosk/.xinitrc"

    #############################################
    # 5. Openbox session desktop file
    #############################################
    mkdir -p "$WORK_DIR/filesystem/usr/share/xsessions"
    cat > "$WORK_DIR/filesystem/usr/share/xsessions/openbox.desktop" << 'DESKTOP'
[Desktop Entry]
Name=Openbox
Comment=Openbox Session
Exec=/usr/bin/openbox-session
TryExec=/usr/bin/openbox
Type=Application
DESKTOP

    #############################################
    # 6. Autologin group (required)
    #############################################
    mount_chroot
    chroot "$WORK_DIR/filesystem" bash -c '
        # Create autologin group and add user
        groupadd -f autologin
        usermod -a -G autologin kiosk
        # Add kiosk to docker group for container access
        usermod -a -G docker kiosk
        
        # Fix ownership
        chown -R kiosk:kiosk /home/kiosk
        chmod 755 /home/kiosk
    '
    unmount_chroot

    #############################################
    # 7. Disable Ctrl+Alt+Delete
    #############################################
    mkdir -p "$WORK_DIR/filesystem/etc/systemd/system"
    ln -sf /dev/null "$WORK_DIR/filesystem/etc/systemd/system/ctrl-alt-del.target"

    #############################################
    # 8. Getty autologin fallback (tty1)
    #############################################
    mkdir -p "$WORK_DIR/filesystem/etc/systemd/system/getty@tty1.service.d"
    cat > "$WORK_DIR/filesystem/etc/systemd/system/getty@tty1.service.d/override.conf" << 'GETTY'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin kiosk --noclear %I $TERM
GETTY

    #############################################
    # 9. Hard Disk Installer Script
    #############################################
    cat > "$WORK_DIR/filesystem/usr/local/bin/install-to-disk.sh" << 'INSTALLER'
#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run with sudo${NC}"
    exit 1
fi

clear
echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}     ${GREEN}KIOSK SYSTEM - HARD DISK INSTALLER${NC}                 ${CYAN}║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}WARNING: This will ERASE the selected disk and install the kiosk system!${NC}"
echo ""

# List available disks
echo -e "${BLUE}Available disks:${NC}"
lsblk -d -o NAME,SIZE,TYPE,MODEL | grep disk
echo ""

# Ask for disk
echo -e "${YELLOW}Enter the disk to install to (e.g., sda, nvme0n1):${NC}"
read -p "Disk: " DISK

if [ -z "$DISK" ]; then
    echo -e "${RED}No disk specified. Exiting.${NC}"
    exit 1
fi

DISK_PATH="/dev/$DISK"

if [ ! -b "$DISK_PATH" ]; then
    echo -e "${RED}Disk $DISK_PATH does not exist!${NC}"
    exit 1
fi

echo ""
echo -e "${RED}═══════════════════════════════════════════════${NC}"
echo -e "${RED}    FINAL WARNING${NC}"
echo -e "${RED}═══════════════════════════════════════════════${NC}"
echo -e "You are about to ERASE: ${RED}$DISK_PATH${NC}"
lsblk "$DISK_PATH"
echo ""
echo -e "${YELLOW}Type 'YES' in capital letters to proceed:${NC}"
read -p "> " CONFIRM

if [ "$CONFIRM" != "YES" ]; then
    echo -e "${GREEN}Installation cancelled.${NC}"
    exit 0
fi

echo ""
echo -e "${GREEN}Starting installation...${NC}"

# Unmount any mounted partitions
umount ${DISK_PATH}* 2>/dev/null || true

# Detect if UEFI or BIOS
if [ -d /sys/firmware/efi ]; then
    echo -e "${BLUE}Detected UEFI system${NC}"
    BOOT_MODE="uefi"
else
    echo -e "${BLUE}Detected BIOS system${NC}"
    BOOT_MODE="bios"
fi

# Partition the disk
echo -e "${BLUE}Partitioning disk...${NC}"

if [ "$BOOT_MODE" = "uefi" ]; then
    # UEFI: GPT with EFI partition
    parted -s "$DISK_PATH" mklabel gpt
    parted -s "$DISK_PATH" mkpart primary fat32 1MiB 512MiB
    parted -s "$DISK_PATH" set 1 esp on
    parted -s "$DISK_PATH" mkpart primary ext4 512MiB 100%
    
    sleep 2
    
    # Format partitions
    if [[ "$DISK" == nvme* ]]; then
        EFI_PART="${DISK_PATH}p1"
        ROOT_PART="${DISK_PATH}p2"
    else
        EFI_PART="${DISK_PATH}1"
        ROOT_PART="${DISK_PATH}2"
    fi
    
    echo -e "${BLUE}Formatting EFI partition...${NC}"
    mkfs.vfat -F 32 "$EFI_PART"
    
    echo -e "${BLUE}Formatting root partition...${NC}"
    mkfs.ext4 -F "$ROOT_PART"
    
    # Mount partitions
    mount "$ROOT_PART" /mnt
    mkdir -p /mnt/boot/efi
    mount "$EFI_PART" /mnt/boot/efi
else
    # BIOS: MBR with single partition
    parted -s "$DISK_PATH" mklabel msdos
    parted -s "$DISK_PATH" mkpart primary ext4 1MiB 100%
    parted -s "$DISK_PATH" set 1 boot on
    
    sleep 2
    
    if [[ "$DISK" == nvme* ]]; then
        ROOT_PART="${DISK_PATH}p1"
    else
        ROOT_PART="${DISK_PATH}1"
    fi
    
    echo -e "${BLUE}Formatting root partition...${NC}"
    mkfs.ext4 -F "$ROOT_PART"
    
    # Mount partition
    mount "$ROOT_PART" /mnt
fi

# Copy system to disk
echo -e "${BLUE}Copying system files (this may take 10-15 minutes)...${NC}"
rsync -aAX --info=progress2 --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found","/cdrom"} / /mnt/

# Create necessary directories
mkdir -p /mnt/{dev,proc,sys,tmp,run,mnt,media,cdrom}
chmod 1777 /mnt/tmp

# Generate fstab
echo -e "${BLUE}Generating fstab...${NC}"
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")

cat > /mnt/etc/fstab << FSTAB
# /etc/fstab: static file system information
UUID=$ROOT_UUID  /  ext4  errors=remount-ro  0  1
FSTAB

if [ "$BOOT_MODE" = "uefi" ]; then
    EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
    echo "UUID=$EFI_UUID  /boot/efi  vfat  umask=0077  0  1" >> /mnt/etc/fstab
fi

# Bind mount for chroot
mount --bind /dev /mnt/dev
mount --bind /dev/pts /mnt/dev/pts
mount --bind /proc /mnt/proc
mount --bind /sys /mnt/sys

# Copy network configuration for apt
cp /etc/resolv.conf /mnt/etc/resolv.conf

# Remove CDROM entries from sources.list to prevent "Media Change" prompts
echo -e "${BLUE}Configuring repositories...${NC}"
sed -i '/deb cdrom/d' /mnt/etc/apt/sources.list

# Ensure we have valid online repos if not present (optional backup)
if ! grep -q "archive.ubuntu.com" /mnt/etc/apt/sources.list; then
    echo "deb http://archive.ubuntu.com/ubuntu noble main restricted universe multiverse" >> /mnt/etc/apt/sources.list
    echo "deb http://archive.ubuntu.com/ubuntu noble-updates main restricted universe multiverse" >> /mnt/etc/apt/sources.list
    echo "deb http://archive.ubuntu.com/ubuntu noble-security main restricted universe multiverse" >> /mnt/etc/apt/sources.list
fi

# Robust Kernel Search Logic
echo -e "${BLUE}Ensuring kernel and initrd are present in /boot...${NC}"

SOURCE_KERNEL=""
SOURCE_INITRD=""
FOUND_LOC=""

# Candidate directories for live media kernel
SEARCH_DIRS=("/cdrom/casper" "/run/live/medium/casper" "/lib/live/mount/medium/casper" "/casper" "/boot")

for dir in "${SEARCH_DIRS[@]}"; do
    if [ -d "$dir" ]; then
        # Try to find kernel file (vmlinuz*)
        K_FILE=$(find "$dir" -maxdepth 1 -name "vmlinuz*" -type f -size +2M | head -n 1)
        # Try to find initrd file (initrd*)
        I_FILE=$(find "$dir" -maxdepth 1 -name "initrd*" -type f -size +5M | head -n 1)
        
        if [ -n "$K_FILE" ] && [ -n "$I_FILE" ]; then
            SOURCE_KERNEL="$K_FILE"
            SOURCE_INITRD="$I_FILE"
            FOUND_LOC="$dir"
            break
        fi
    fi
done

if [ -z "$SOURCE_KERNEL" ]; then
    echo -e "${RED}CRITICAL ERROR: Could not find kernel (vmlinuz) or initrd!${NC}"
    echo "Checked: ${SEARCH_DIRS[*]}"
    echo "Installation cannot proceed as the system will not boot."
    exit 1
fi

echo -e "${GREEN}Found kernel source at: $FOUND_LOC${NC}"
echo "  Kernel: $SOURCE_KERNEL"
echo "  Initrd: $SOURCE_INITRD"

KVER=$(uname -r)
# Ensure we copying to standard names for update-grub to detect
TARGET_KERNEL="/mnt/boot/vmlinuz-$KVER"
TARGET_INITRD="/mnt/boot/initrd.img-$KVER"

echo "Copying to $TARGET_KERNEL..."
cp "$SOURCE_KERNEL" "$TARGET_KERNEL" || { echo -e "${RED}Copy failed!${NC}"; exit 1; }
cp "$SOURCE_INITRD" "$TARGET_INITRD" || { echo -e "${RED}Copy failed!${NC}"; exit 1; }

# EXTRA: Copy the entire source directory (casper) to /mnt/boot/casper as requested
# This ensures filesystem.squashfs etc are present if user wants them
if [ -d "$FOUND_LOC" ]; then
    echo "Copying all files from $FOUND_LOC to /mnt/boot/casper/..."
    mkdir -p /mnt/boot/casper
    cp -r "$FOUND_LOC/"* /mnt/boot/casper/ 2>/dev/null || true
fi

# Legacy/Fallback: Copy unversioned files to /mnt/
echo "Creating fallback copies in /mnt/..."
cp "$SOURCE_KERNEL" /mnt/vmlinuz
cp "$SOURCE_INITRD" /mnt/initrd.img

# Create symlinks in root for safety (some old grubs look here)
ln -sf "boot/vmlinuz-$KVER" /mnt/vmlinuz
ln -sf "boot/initrd.img-$KVER" /mnt/initrd.img
ln -sf "vmlinuz-$KVER" /mnt/boot/vmlinuz
ln -sf "initrd.img-$KVER" /mnt/boot/initrd.img

# Install GRUB packages based on boot mode
echo -e "${BLUE}Installing GRUB packages...${NC}"

# Check if we have internet connectivity
if ping -c 1 8.8.8.8 &> /dev/null || ping -c 1 1.1.1.1 &> /dev/null; then
    echo -e "${GREEN}Internet connection detected, installing GRUB from repositories...${NC}"
    
    if [ "$BOOT_MODE" = "uefi" ]; then
        echo -e "${BLUE}Installing GRUB for UEFI...${NC}"
        DEBIAN_FRONTEND=noninteractive chroot /mnt apt update
        DEBIAN_FRONTEND=noninteractive chroot /mnt apt install -y grub-efi-amd64 grub-efi-amd64-signed shim-signed 2>/dev/null || \
        DEBIAN_FRONTEND=noninteractive chroot /mnt apt install -y grub-efi-amd64
    else
        echo -e "${BLUE}Installing GRUB for BIOS...${NC}"
        DEBIAN_FRONTEND=noninteractive chroot /mnt apt update
        
        # Preseed grub-pc to avoid interactive prompts
        echo "grub-pc grub-pc/install_devices multiselect $DISK_PATH" | chroot /mnt debconf-set-selections
        echo "grub-pc grub-pc/install_devices_empty boolean false" | chroot /mnt debconf-set-selections
        
        DEBIAN_FRONTEND=noninteractive chroot /mnt apt install -y grub-pc
    fi
else
    echo -e "${YELLOW}No internet connection, using existing GRUB files...${NC}"
    echo -e "${YELLOW}Note: GRUB updates will not be available${NC}"
    
    if [ "$BOOT_MODE" = "uefi" ]; then
        # Copy GRUB EFI files from live system
        if [ -d /usr/lib/grub/x86_64-efi ]; then
            mkdir -p /mnt/usr/lib/grub/x86_64-efi
            cp -r /usr/lib/grub/x86_64-efi/* /mnt/usr/lib/grub/x86_64-efi/
        fi
        if [ -f /usr/lib/shim/shimx64.efi.signed ]; then
            mkdir -p /mnt/usr/lib/shim
            cp /usr/lib/shim/shimx64.efi.signed /mnt/usr/lib/shim/
        fi
    else
        # Copy GRUB BIOS files from live system
        if [ -d /usr/lib/grub/i386-pc ]; then
            mkdir -p /mnt/usr/lib/grub/i386-pc
            cp -r /usr/lib/grub/i386-pc/* /mnt/usr/lib/grub/i386-pc/
        fi
    fi
fi

# Install GRUB
echo -e "${BLUE}Installing GRUB bootloader...${NC}"

if [ "$BOOT_MODE" = "uefi" ]; then
    chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck
else
    chroot /mnt grub-install --target=i386-pc "$DISK_PATH"
fi

# Update GRUB config
cat > /mnt/etc/default/grub << 'GRUBDEFAULT'
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Kiosk"
GRUB_CMDLINE_LINUX_DEFAULT="nomodeset"
GRUB_CMDLINE_LINUX=""
GRUB_TERMINAL=console
GRUBDEFAULT

chroot /mnt update-grub

# Cleanup
echo -e "${BLUE}Cleaning up...${NC}"
umount /mnt/dev/pts
umount /mnt/dev
umount /mnt/proc
umount /mnt/sys

if [ "$BOOT_MODE" = "uefi" ]; then
    umount /mnt/boot/efi
fi

umount /mnt

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║${NC}     ${CYAN}INSTALLATION COMPLETE!${NC}                             ${GREEN}║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}The kiosk system has been installed to $DISK_PATH${NC}"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo -e "  1. Remove the installation media (USB/CD)"
echo -e "  2. Reboot the system: ${CYAN}sudo reboot${NC}"
echo -e "  3. System will boot directly from the hard disk"
echo ""
echo -e "${BLUE}Credentials:${NC}"
echo -e "  Username: kiosk"
echo -e "  Password: kiosk"
echo ""
echo -e "${YELLOW}Press Enter to reboot now, or Ctrl+C to cancel...${NC}"
read
reboot
INSTALLER

    chmod +x "$WORK_DIR/filesystem/usr/local/bin/install-to-disk.sh"

    #############################################
    # 10. Create desktop shortcut for installer (live session)
    #############################################
    mkdir -p "$WORK_DIR/filesystem/home/kiosk/Desktop"
    cat > "$WORK_DIR/filesystem/home/kiosk/Desktop/install-to-disk.desktop" << 'DESKTOP_INSTALL'
[Desktop Entry]
Type=Application
Name=Install to Hard Disk
Comment=Install Kiosk System to Hard Disk
Exec=sudo /usr/local/bin/install-to-disk.sh
Icon=system-software-install
Terminal=true
Categories=System;
DESKTOP_INSTALL

    chmod +x "$WORK_DIR/filesystem/home/kiosk/Desktop/install-to-disk.desktop"

    log "Kiosk configuration files created"
}

create_installer_autorun() {
    log "Creating installer auto-prompt..."
    
    #############################################
    # Optional: Show installer prompt in terminal mode
    #############################################
    cat > "$WORK_DIR/filesystem/usr/local/bin/installer-prompt.sh" << 'PROMPT'
#!/bin/bash

# Check if running from live session (no /etc/fstab with real partitions)
if ! grep -q "^UUID=" /etc/fstab 2>/dev/null; then
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  Running from LIVE SESSION (not installed to disk)"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    echo "To install this kiosk system permanently to hard disk:"
    echo "  Run: sudo install-to-disk.sh"
    echo ""
    echo "This will copy all files to disk for persistent storage."
    echo "═══════════════════════════════════════════════════════════"
    echo ""
fi
PROMPT

    chmod +x "$WORK_DIR/filesystem/usr/local/bin/installer-prompt.sh"
    
    # Add to bashrc for kiosk user
    echo "" >> "$WORK_DIR/filesystem/home/kiosk/.bashrc"
    echo "# Show installer prompt if running live" >> "$WORK_DIR/filesystem/home/kiosk/.bashrc"
    echo "/usr/local/bin/installer-prompt.sh" >> "$WORK_DIR/filesystem/home/kiosk/.bashrc"

    log "Kiosk configuration files created"
}

update_grub_config() {
    log "Updating GRUB configuration..."
    
    mkdir -p "$WORK_DIR/extract/boot/grub"
    
    cat > "$WORK_DIR/extract/boot/grub/grub.cfg" << 'GRUB'
set timeout=5
set default=0

insmod all_video
insmod gfxterm

set gfxmode=auto
set gfxpayload=keep

menuentry "Ubuntu Kiosk 24.04 - Chrome Fullscreen (Default)" {
    set gfxpayload=keep
    linux /casper/vmlinuz boot=casper kiosk_mode=chrome quiet splash ---
    initrd /casper/initrd
}

menuentry "Ubuntu Kiosk 24.04 - Terminal Mode" {
    set gfxpayload=keep
    linux /casper/vmlinuz boot=casper kiosk_mode=terminal quiet splash ---
    initrd /casper/initrd
}

menuentry "Ubuntu Kiosk 24.04 (Safe Graphics)" {
    linux /casper/vmlinuz boot=casper kiosk_mode=chrome xforcevesa nomodeset quiet splash ---
    initrd /casper/initrd
}

menuentry "Ubuntu Kiosk 24.04 (Debug)" {
    linux /casper/vmlinuz boot=casper debug nosplash ---
    initrd /casper/initrd
}
GRUB

    log "Copying kernel and initrd..."
    
    KERNEL=$(ls "$WORK_DIR/filesystem/boot/vmlinuz-"* 2>/dev/null | head -1)
    INITRD=$(ls "$WORK_DIR/filesystem/boot/initrd.img-"* 2>/dev/null | head -1)
    
    if [ -n "$KERNEL" ] && [ -f "$KERNEL" ]; then
        cp "$KERNEL" "$WORK_DIR/extract/casper/vmlinuz"
        log "Kernel: $(basename $KERNEL)"
    else
        error "Kernel not found"
    fi
    
    if [ -n "$INITRD" ] && [ -f "$INITRD" ]; then
        cp "$INITRD" "$WORK_DIR/extract/casper/initrd"
        log "Initrd: $(basename $INITRD)"
    else
        error "Initrd not found"
    fi
    
    cat > "$WORK_DIR/extract/boot/grub/loopback.cfg" << 'LOOPBACK'
menuentry "Ubuntu Kiosk 24.04 + Docker" {
    linux /casper/vmlinuz boot=casper iso-scan/filename=${iso_path} quiet splash ---
    initrd /casper/initrd
}
LOOPBACK
}

rebuild_squashfs() {
    log "Rebuilding squashfs filesystem..."
    log "This may take 10-15 minutes..."
    
    rm -f "$WORK_DIR/extract/casper/"*.squashfs
    
    # Clean up before squashing
    rm -rf "$WORK_DIR/filesystem/var/cache/apt/archives/"*.deb
    rm -rf "$WORK_DIR/filesystem/var/lib/apt/lists/"*
    rm -rf "$WORK_DIR/filesystem/tmp/"*
    
    mksquashfs "$WORK_DIR/filesystem" "$WORK_DIR/extract/casper/filesystem.squashfs" \
        -comp xz \
        -b 1M \
        -noappend
    
    printf $(du -sx --block-size=1 "$WORK_DIR/filesystem" | cut -f1) > "$WORK_DIR/extract/casper/filesystem.size"
    
    mount_chroot
    chroot "$WORK_DIR/filesystem" dpkg-query -W --showformat='${Package} ${Version}\n' \
        > "$WORK_DIR/extract/casper/filesystem.manifest" 2>/dev/null || true
    unmount_chroot
    
    log "Squashfs created: $(du -h "$WORK_DIR/extract/casper/filesystem.squashfs" | cut -f1)"
}

build_iso() {
    log "Building ISO image..."
    
    cd "$WORK_DIR/extract"
    
    log "Generating checksums..."
    find . -type f -not -name "md5sum.txt" -not -path "./isolinux/*" -print0 | \
        xargs -0 md5sum > md5sum.txt 2>/dev/null || true
    
    cd "$WORK_DIR"
    
    create_efi_image
    
    log "Verifying boot files..."
    
    [ -f "$WORK_DIR/efi.img" ] || error "EFI image not found"
    
    if [ ! -f "$WORK_DIR/extract/boot/grub/i386-pc/eltorito.img" ]; then
        mkdir -p "$WORK_DIR/extract/boot/grub/i386-pc"
        grub-mkimage -O i386-pc-eltorito \
            -o "$WORK_DIR/extract/boot/grub/i386-pc/eltorito.img" \
            -p /boot/grub \
            biosdisk iso9660 normal search configfile linux loopback chain \
            part_msdos part_gpt fat ext2 all_video
    fi
    
    [ -f "$WORK_DIR/extract/casper/vmlinuz" ] || error "Kernel not found"
    [ -f "$WORK_DIR/extract/casper/initrd" ] || error "Initrd not found"
    [ -f "$WORK_DIR/extract/casper/filesystem.squashfs" ] || error "Squashfs not found"
    
    log "All boot files verified"
    log "Building ISO..."
    
    xorriso -as mkisofs \
        -r \
        -V "UBUNTU_KIOSK_DOCKER" \
        -o "${ISO_NAME}.iso" \
        -J -joliet-long \
        -l \
        -iso-level 3 \
        -partition_offset 16 \
        --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img \
        --mbr-force-bootable \
        -append_partition 2 0xef "$WORK_DIR/efi.img" \
        -appended_part_as_gpt \
        -c boot.catalog \
        -b boot/grub/i386-pc/eltorito.img \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        --grub2-boot-info \
        -eltorito-alt-boot \
        -e --interval:appended_partition_2:all:: \
        -no-emul-boot \
        -follow-links \
        extract/
    
    if [ -f "${ISO_NAME}.iso" ]; then
        log "✓ ISO created successfully!"
        log "  Location: $WORK_DIR/${ISO_NAME}.iso"
        log "  Size: $(du -h "${ISO_NAME}.iso" | cut -f1)"
    else
        error "Failed to create ISO"
    fi
}

show_summary() {
    echo ""
    echo "=============================================="
    echo -e "${GREEN}       BUILD COMPLETE${NC}"
    echo "=============================================="
    echo ""
    echo "ISO File: $WORK_DIR/${ISO_NAME}.iso"
    echo "Size: $(du -h "$WORK_DIR/${ISO_NAME}.iso" | cut -f1)"
    echo ""
    echo "=============================================="
    echo "         KIOSK FEATURES"
    echo "=============================================="
    echo "  ✓ Auto-login as 'kiosk' user"
    echo "  ✓ NetworkManager with netplan configured"
    echo "  ✓ Automatic network detection (Ethernet/WiFi)"
    echo "  ✓ Docker pre-installed"
    echo "  ✓ Docker container auto-starts: $DOCKER_IMAGE"
    echo "  ✓ Nginx web server on port 80 (fallback)"
    echo "  ✓ curl, vim, nano pre-installed"
    echo "  ✓ Hard disk installer included"
    echo "  ✓ Two display modes available:"
    echo "     - Chrome fullscreen kiosk (default)"
    echo "     - Terminal mode with system info"
    echo "  ✓ Smart URL detection (Docker:8090 → Nginx:80)"
    echo "  ✓ URL bar completely hidden (Chrome mode)"
    echo "  ✓ Mouse cursor auto-hides (Chrome mode)"
    echo "  ✓ Screen never blanks"
    echo "  ✓ Auto-restart if Chrome crashes"
    echo "  ✓ Keyboard shortcuts disabled (Chrome mode)"
    echo ""
    echo "=============================================="
    echo "         CREDENTIALS"
    echo "=============================================="
    echo "  Username: $KIOSK_USER"
    echo "  Password: $KIOSK_PASS"
    echo "  URL: $KIOSK_URL"
    echo "  Docker Image: $DOCKER_IMAGE"
    echo "  Container Port: $DOCKER_PORT"
    echo ""
    echo "=============================================="
    echo "         SSH ACCESS"
    echo "=============================================="
    echo "  SSH is enabled and listening on port 22"
    echo "  Connect from LAN:"
    echo "    ssh kiosk@<KIOSK_IP_ADDRESS>"
    echo "  Password: $KIOSK_PASS"
    echo ""
    echo "  View network info on kiosk:"
    echo "    Press Ctrl+Alt+F2 (tty2)"
    echo "    Press Ctrl+Alt+F1 to return"
    echo ""
    echo "=============================================="
    echo "         BOOT OPTIONS"
    echo "=============================================="
    echo "  At boot menu, select:"
    echo "   1. Chrome Fullscreen (Default)"
    echo "      - Full kiosk mode with hidden UI"
    echo "      - Auto-opens app at http://127.0.0.1:8090"
    echo ""
    echo "   2. Terminal Mode"
    echo "      - Interactive terminal interface"
    echo "      - System info and quick commands"
    echo "      - Switch modes from menu"
    echo ""
    echo "  Change mode after boot:"
    echo "    - In Terminal: Select option 5"
    echo "    - Via SSH: echo 'KIOSK_MODE=\"terminal\"' | sudo tee /etc/kiosk-mode.conf && sudo reboot"
    echo ""
    echo "=============================================="
    echo "         INSTALLATION"
    echo "=============================================="
    echo "  The ISO boots in LIVE mode (runs from RAM)"
    echo ""
    echo "  To install permanently to hard disk:"
    echo "    1. Boot from ISO/USB"
    echo "    2. Switch to Terminal mode (or press Ctrl+Alt+F2)"
    echo "    3. Run: sudo install-to-disk.sh"
    echo "    4. Follow the prompts"
    echo "    5. Remove USB and reboot"
    echo ""
    echo "  Or in Terminal mode menu: Select option 0"
    echo ""
    echo "  After installation:"
    echo "    - System boots directly from hard disk"
    echo "    - All changes are persistent"
    echo "    - Docker images are saved"
    echo "    - No USB needed"
    echo ""
    echo "=============================================="
    echo "         CACHE INFO"
    echo "=============================================="
    echo "  Cache Dir: $CACHE_DIR"
    echo "  Base System: $(du -h "$CACHE_DIR/base-system.tar.gz" 2>/dev/null | cut -f1 || echo 'Not cached')"
    echo "  APT Packages: $(ls "$CACHE_DIR/apt-archives/"*.deb 2>/dev/null | wc -l) packages"
    echo "  Chrome: $(du -h "$CACHE_DIR/chrome/google-chrome-stable_current_amd64.deb" 2>/dev/null | cut -f1 || echo 'Not cached')"
    echo ""
    echo "  Next build will be much faster!"
    echo ""
    echo "=============================================="
    echo "         TEST COMMANDS"
    echo "=============================================="
    echo ""
    echo "QEMU (with KVM):"
    echo "  qemu-system-x86_64 -m 4096 -enable-kvm -cdrom $WORK_DIR/${ISO_NAME}.iso"
    echo ""
    echo "QEMU (without KVM):"
    echo "  qemu-system-x86_64 -m 4096 -cdrom $WORK_DIR/${ISO_NAME}.iso"
    echo ""
    echo "Write to USB (replace /dev/sdX):"
    echo "  sudo dd if=$WORK_DIR/${ISO_NAME}.iso of=/dev/sdX bs=4M status=progress conv=fsync"
    echo ""
}

show_cache_stats() {
    echo ""
    log "=============================================="
    log "         CACHE STATISTICS"
    log "=============================================="
    
    TOTAL_CACHE=0
    
    if [ -f "$CACHE_DIR/base-system.tar.gz" ]; then
        SIZE=$(du -b "$CACHE_DIR/base-system.tar.gz" | cut -f1)
        TOTAL_CACHE=$((TOTAL_CACHE + SIZE))
        info "Base system cache: $(du -h "$CACHE_DIR/base-system.tar.gz" | cut -f1)"
    fi
    
    if [ -d "$CACHE_DIR/apt-archives" ]; then
        SIZE=$(du -sb "$CACHE_DIR/apt-archives" | cut -f1)
        TOTAL_CACHE=$((TOTAL_CACHE + SIZE))
        COUNT=$(ls "$CACHE_DIR/apt-archives/"*.deb 2>/dev/null | wc -l)
        info "APT cache: $COUNT packages ($(du -sh "$CACHE_DIR/apt-archives" | cut -f1))"
    fi
    
    if [ -f "$CACHE_DIR/chrome/google-chrome-stable_current_amd64.deb" ]; then
        SIZE=$(du -b "$CACHE_DIR/chrome/google-chrome-stable_current_amd64.deb" | cut -f1)
        TOTAL_CACHE=$((TOTAL_CACHE + SIZE))
        info "Chrome cache: $(du -h "$CACHE_DIR/chrome/google-chrome-stable_current_amd64.deb" | cut -f1)"
    fi
    
    info "Total cache size: $(numfmt --to=iec $TOTAL_CACHE)"
    echo ""
}

cleanup_on_exit() {
    unmount_chroot 2>/dev/null || true
    umount -lf "$WORK_DIR/efi_mount" 2>/dev/null || true
    umount -lf "$WORK_DIR/mnt" 2>/dev/null || true
}

clear_cache() {
    log "Clearing all cached files..."
    rm -rf "$CACHE_DIR"
    log "Cache cleared"
}

trap 'cleanup_on_exit; exit 1' INT TERM

main() {
    echo ""
    log "=============================================="
    log "   Ubuntu 24.04 Kiosk ISO Builder v5"
    log "   With Docker Support"
    log "=============================================="
    echo ""
    log "Source ISO: $SOURCE_ISO"
    log "Work Dir: $WORK_DIR"
    log "Cache Dir: $CACHE_DIR"
    log "Output: $WORK_DIR/${ISO_NAME}.iso"
    log "Kiosk URL: $KIOSK_URL"
    log "Docker Image: $DOCKER_IMAGE"
    echo ""
    
    # Handle --clear-cache argument
    if [ "$1" == "--clear-cache" ]; then
        clear_cache
        exit 0
    fi
    
    if [ ! -f "$SOURCE_ISO" ]; then
        error "Source ISO not found: $SOURCE_ISO"
    fi
    
    START_TIME=$(date +%s)
    
    check_root
    install_deps
    setup_cache
    setup_dirs
    extract_iso_structure
    create_base_system
    configure_system
    create_kiosk_configs
    update_grub_config
    rebuild_squashfs
    build_iso
    
    END_TIME=$(date +%s)
    BUILD_TIME=$((END_TIME - START_TIME))
    BUILD_MINS=$((BUILD_TIME / 60))
    BUILD_SECS=$((BUILD_TIME % 60))
    
    show_summary
    show_cache_stats
    
    log "Build time: ${BUILD_MINS}m ${BUILD_SECS}s"
    
    cleanup_on_exit
    
    log "=============================================="
    log "Build complete!"
    log "=============================================="
}

main "$@"