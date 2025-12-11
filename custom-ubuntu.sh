#!/bin/bash
# build-kiosk-iso-v5.sh
# Optimized with caching + verified auto-login

set -e

ISO_NAME="ubuntu-24.04-kiosk"
WORK_DIR="/home/ubuntu/custom-iso"
CACHE_DIR="/home/ubuntu/iso-cache"
SOURCE_ISO="/home/ubuntu/Downloads/ubuntu-24.04.3-live-server-amd64.iso"

# Kiosk settings
KIOSK_URL="http://localhost"
KIOSK_USER="kiosk"
KIOSK_PASS="kiosk"

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
    
    mkdir -p "$CACHE_DIR"/{debootstrap,apt-archives,chrome}
    
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

configure_system() {
    log "Configuring system inside chroot..."
    
    # Download Chrome first (outside chroot for caching)
    download_chrome
    
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
    curl

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
    alsa-utils

echo "Installing nginx..."
apt install -y nginx

echo "Installing Chrome dependencies (Ubuntu 24.04 t64 packages)..."
apt install -y \
    wget \
    gnupg \
    ca-certificates \
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
useradd -m -s /bin/bash -G audio,video,sudo,plugdev,netdev kiosk
echo "kiosk:kiosk" | chpasswd

# Allow kiosk user passwordless sudo for specific commands
echo "kiosk ALL=(ALL) NOPASSWD: /sbin/reboot, /sbin/shutdown" > /etc/sudoers.d/kiosk
chmod 440 /etc/sudoers.d/kiosk

echo "Enabling services..."
systemctl enable lightdm
systemctl enable nginx
systemctl enable NetworkManager
systemctl enable ssh

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
    # 1. Web page (served by nginx)
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
        html, body { 
            height: 100%; 
            overflow: hidden;
            user-select: none;
            -webkit-user-select: none;
        }
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #1a1a2e 0%, #16213e 50%, #0f3460 100%);
            min-height: 100vh;
            display: flex;
            justify-content: center;
            align-items: center;
            color: white;
        }
        .container {
            text-align: center;
            padding: 60px;
            background: rgba(255,255,255,0.05);
            border-radius: 30px;
            backdrop-filter: blur(20px);
            border: 1px solid rgba(255,255,255,0.1);
            box-shadow: 0 25px 50px rgba(0,0,0,0.3);
        }
        .logo { font-size: 5rem; margin-bottom: 20px; }
        h1 { 
            font-size: 3.5rem; 
            margin-bottom: 15px;
            font-weight: 300;
            letter-spacing: 2px;
        }
        .subtitle { font-size: 1.2rem; opacity: 0.7; margin-bottom: 40px; }
        .time {
            font-size: 4rem;
            font-weight: 200;
            margin: 30px 0;
            font-family: 'Courier New', monospace;
        }
        .date { font-size: 1.5rem; opacity: 0.8; margin-bottom: 40px; }
        .status {
            display: inline-block;
            padding: 15px 40px;
            background: linear-gradient(135deg, rgba(76,175,80,0.3), rgba(56,142,60,0.3));
            border-radius: 50px;
            border: 2px solid #4CAF50;
            font-size: 1.1rem;
        }
        .status::before {
            content: "●";
            color: #4CAF50;
            margin-right: 10px;
            animation: pulse 2s infinite;
        }
        @keyframes pulse {
            0%, 100% { opacity: 1; }
            50% { opacity: 0.3; }
        }
    </style>
</head>
<body oncontextmenu="return false;">
    <div class="container">
        <div class="logo">🖥️</div>
        <h1>KIOSK SYSTEM</h1>
        <p class="subtitle">Ubuntu 24.04 LTS</p>
        <div class="time" id="clock">00:00:00</div>
        <div class="date" id="date">Loading...</div>
        <div class="status">SYSTEM ONLINE</div>
    </div>
    <script>
        document.addEventListener('keydown', function(e) {
            if (e.key === 'F11' || e.key === 'Escape' || 
                (e.ctrlKey && (e.key === 'r' || e.key === 'w' || e.key === 't' || e.key === 'n')) ||
                (e.altKey && e.key === 'F4')) {
                e.preventDefault();
                return false;
            }
        });
        
        function updateClock() {
            const now = new Date();
            document.getElementById('clock').textContent = 
                now.toLocaleTimeString('en-US', { hour12: false });
            document.getElementById('date').textContent = 
                now.toLocaleDateString('en-US', { 
                    weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' 
                });
        }
        setInterval(updateClock, 1000);
        updateClock();
    </script>
</body>
</html>
HTML

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
    
    # Openbox autostart - MAIN KIOSK SCRIPT
    cat > "$WORK_DIR/filesystem/home/kiosk/.config/openbox/autostart" << 'AUTOSTART'
#!/bin/bash

# Log for debugging
exec >> /home/kiosk/kiosk.log 2>&1
echo "=== Kiosk starting at $(date) ==="

# Wait for X to be ready
sleep 2

# Disable screen blanking and power management
xset s off
xset s noblank
xset -dpms
xset s 0 0

# Hide cursor after 0.5 seconds
unclutter-xfixes --timeout 0.5 --jitter 2 --hide-on-touch &

# Wait for nginx
echo "Waiting for nginx..."
for i in {1..30}; do
    if curl -s http://localhost > /dev/null 2>&1; then
        echo "Nginx ready"
        break
    fi
    sleep 1
done

# Clean Chrome profile
rm -rf /home/kiosk/.config/google-chrome/Singleton* 2>/dev/null
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

# Chrome FULL KIOSK mode - NO UI visible
while true; do
    google-chrome-stable \
        --kiosk \
        --no-first-run \
        --no-default-browser-check \
        --disable-translate \
        --disable-infobars \
        --disable-suggestions-service \
        --disable-save-password-bubble \
        --disable-session-crashed-bubble \
        --disable-component-update \
        --disable-background-networking \
        --disable-sync \
        --disable-features=TranslateUI \
        --disable-hang-monitor \
        --disable-prompt-on-repost \
        --autoplay-policy=no-user-gesture-required \
        --noerrdialogs \
        --no-message-box \
        --start-fullscreen \
        --start-maximized \
        --window-position=0,0 \
        --user-data-dir=/home/kiosk/.config/google-chrome \
        --disable-pinch \
        --overscroll-history-navigation=0 \
        --password-store=basic \
        --check-for-update-interval=31536000 \
        --simulate-outdated-no-au='Tue, 31 Dec 2099 23:59:59 GMT' \
        --app=http://localhost
    
    echo "Chrome exited at $(date), restarting..."
    sleep 3
done
AUTOSTART

    chmod +x "$WORK_DIR/filesystem/home/kiosk/.config/openbox/autostart"

    # Openbox rc.xml - minimal config, no decorations
    cat > "$WORK_DIR/filesystem/home/kiosk/.config/openbox/rc.xml" << 'RCXML'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <resistance><strength>10</strength><screen_edge_strength>20</screen_edge_strength></resistance>
  <focus><focusNew>yes</focusNew><followMouse>no</followMouse></focus>
  <placement><policy>Smart</policy><center>yes</center></placement>
  <theme><name>Clearlooks</name><keepBorder>no</keepBorder></theme>
  <desktops><number>1</number><popupTime>0</popupTime></desktops>
  <keyboard></keyboard>
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

    log "Kiosk configuration files created"
}

update_grub_config() {
    log "Updating GRUB configuration..."
    
    mkdir -p "$WORK_DIR/extract/boot/grub"
    
    cat > "$WORK_DIR/extract/boot/grub/grub.cfg" << 'GRUB'
set timeout=3
set default=0

insmod all_video
insmod gfxterm

set gfxmode=auto
set gfxpayload=keep

menuentry "Ubuntu Kiosk 24.04" {
    set gfxpayload=keep
    linux /casper/vmlinuz boot=casper quiet splash ---
    initrd /casper/initrd
}

menuentry "Ubuntu Kiosk 24.04 (Safe Graphics)" {
    linux /casper/vmlinuz boot=casper xforcevesa nomodeset quiet splash ---
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
menuentry "Ubuntu Kiosk 24.04" {
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
        -noappend \
        -e boot
    
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
        -V "UBUNTU_KIOSK_2404" \
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
    echo "  ✓ Chrome in full kiosk mode"
    echo "  ✓ URL bar completely hidden"
    echo "  ✓ All browser UI hidden"
    echo "  ✓ Mouse cursor auto-hides"
    echo "  ✓ Screen never blanks"
    echo "  ✓ Auto-restart if Chrome crashes"
    echo "  ✓ Keyboard shortcuts disabled"
    echo ""
    echo "=============================================="
    echo "         CREDENTIALS"
    echo "=============================================="
    echo "  Username: $KIOSK_USER"
    echo "  Password: $KIOSK_PASS"
    echo "  URL: $KIOSK_URL"
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
    log "   With Package Caching"
    log "=============================================="
    echo ""
    log "Source ISO: $SOURCE_ISO"
    log "Work Dir: $WORK_DIR"
    log "Cache Dir: $CACHE_DIR"
    log "Output: $WORK_DIR/${ISO_NAME}.iso"
    log "Kiosk URL: $KIOSK_URL"
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