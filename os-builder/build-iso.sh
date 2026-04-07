#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/output"
OS_NAME="docker-registry-os"
VERSION="1.0.0"
ISO_NAME="${OS_NAME}-${VERSION}-amd64.iso"
RAM_SIZE=1024
DISK_SIZE=10G

mkdir -p "${OUTPUT_DIR}"

echo "Building standalone Docker Registry OS..."

# Build the registry binary
echo "Building Go backend..."
cd "${SCRIPT_DIR}/../backend"
if [ ! -f "go.mod" ]; then
    go mod init docker-registry
    go mod tidy
fi
CGO_ENABLED=1 GOOS=linux GOARCH=amd64 go build -o registry -ldflags="-s -w" .

# Copy frontend
cp "${SCRIPT_DIR}/../frontend/index.html" "${SCRIPT_DIR}/../backend/static/"

# Create rootfs
ROOTFS="${OUTPUT_DIR}/rootfs"
rm -rf "${ROOTFS}"
mkdir -p "${ROOTFS}"

# Create minimal Alpine-based rootfs
echo "Creating minimal rootfs..."
mkdir -p "${ROOTFS}/"{bin,etc,home,lib,media,mnt,opt,proc,root,run,srv,sys,tmp,usr,var,data}

# Install Alpine base
 ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine/v3.19"
 
 # Download and extract Alpine minimal
echo "Downloading Alpine base..."
curl -sL "${ALPINE_MIRROR}/releases/x86_64/alpine-minirootfs-3.19.1-x86_64.tar.gz" | tar xz -C "${ROOTFS}"

# Create init script
cat > "${ROOTFS}/init" << 'INITEOF'
#!/bin/sh
mount -t proc /proc /proc
mount -t sysfs /sys /sys
mount -o remount,rw /

echo "Starting Docker Registry OS..."

# Initialize database if needed
if [ ! -f "/data/registry.db" ]; then
    echo "Initializing database..."
fi

# Start registry
exec /usr/bin/registry
INITEOF
chmod +x "${ROOTFS}/init"

# Copy registry binary
cp "${SCRIPT_DIR}/../backend/registry" "${ROOTFS}/usr/bin/"

# Copy static files
mkdir -p "${ROOTFS}/app/static"
cp "${SCRIPT_DIR}/../frontend/index.html" "${ROOTFS}/app/static/"

# Create startup script
cat > "${ROOTFS}/usr/local/bin/start-registry.sh" << 'STARTEOF'
#!/bin/sh
echo "Starting Docker Registry..."
exec /usr/bin/registry
STARTEOF
chmod +x "${ROOTFS}/usr/local/bin/start-registry.sh"

# Create fstab
cat > "${ROOTFS}/etc/fstab" << 'FSTABEOF'
/dev/sda1 / ext4 defaults 0 1
proc /proc proc defaults 0 0
sysfs /sys sysfs defaults 0 0
devpts /dev/pts devpts defaults 0 0
FSTABEOF

# Create network configuration
cat > "${ROOTFS}/etc/network" << 'NETEOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
NETEOF

# Create resolv.conf
cat > "${ROOTFS}/etc/resolv.conf" << 'RESOLVEOF'
nameserver 8.8.8.8
nameserver 8.8.4.4
RESOLVEOF

# Create inittab
cat > "${ROOTFS}/etc/inittab" << 'INITTABEOF'
::sysinit:/etc/init.d/rcS
::respawn:/usr/local/bin/start-registry.sh
::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/swapoff -a
INITTABEOF

# Create init.d directory
mkdir -p "${ROOTFS}/etc/init.d"
cat > "${ROOTFS}/etc/init.d/rcS" << 'RCSEOF'
#!/bin/sh
mount -a
mkdir -p /var/log /var/run /var/lib /data
echo "System initialized"
RCSEOF
chmod +x "${ROOTFS}/etc/init.d/rcS"

# Create environment file
cat > "${ROOTFS}/etc/registry.env" << 'ENVEOF'
PORT=8080
DB_DRIVER=sqlite
DB_SOURCE=/data/registry.db
JWT_SECRET=docker-registry-default-secret-change-me
ADMIN_USERNAME=admin
ADMIN_PASSWORD=admin123
ADMIN_EMAIL=admin@localhost
HTTPS_ENABLED=false
ENVEOF

echo "Rootfs created successfully"
echo "Location: ${ROOTFS}"

# Create ISO using mkisofs or genisoimage
echo "Creating ISO image..."

# Check for mkisofs or genisoimage
if command -v mkisofs >/dev/null 2>&1; then
    MKISOFS="mkisofs"
elif command -v genisoimage >/dev/null 2>&1; then
    MKISOFS="genisoimage"
else
    echo "ERROR: genisoimage or mkisofs not found"
    echo "Install with: apt-get install genisoimage"
    exit 1
fi

# Create bootable ISO
${MKISOFS} \
    -o "${OUTPUT_DIR}/${ISO_NAME}" \
    -b boot/isohybrid.bin \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -R \
    -J \
    -V "DOCKER_REGISTRY" \
    "${ROOTFS}"

echo "ISO created: ${OUTPUT_DIR}/${ISO_NAME}"
echo "Done!"
