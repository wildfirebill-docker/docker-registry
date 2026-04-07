#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/output"
VM_NAME="docker-registry-vm"
VERSION="1.0.0"
DISK_SIZE=10G

mkdir -p "${OUTPUT_DIR}"

echo "Building VM image for Docker Registry..."

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

# Create rootfs directory
ROOTFS="${OUTPUT_DIR}/rootfs"
rm -rf "${ROOTFS}"
mkdir -p "${ROOTFS}"/{bin,etc,home,lib,media,mnt,opt,proc,root,run,srv,sys,tmp,usr,var,data}

# Download Alpine minimal rootfs
echo "Downloading Alpine base..."
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine/v3.19"
curl -sL "${ALPINE_MIRROR}/releases/x86_64/alpine-minirootfs-3.19.1-x86_64.tar.gz" | tar xz -C "${ROOTFS}"

# Install additional packages
echo "Installing packages..."
ROOTFS_PATH="${ROOTFS}" chroot "${ROOTFS}" /bin/sh -c "
apk add --no-cache sqlite bash curl openssl
"

# Copy registry binary
cp "${SCRIPT_DIR}/../backend/registry" "${ROOTFS}/usr/bin/"

# Copy static files
mkdir -p "${ROOTFS}/app/static"
cp "${SCRIPT_DIR}/../frontend/index.html" "${ROOTFS}/app/static/"

# Create startup script
cat > "${ROOTFS}/usr/local/bin/start-registry.sh" << 'STARTEOF'
#!/bin/sh
exec /usr/bin/registry
STARTEOF
chmod +x "${ROOTFS}/usr/local/bin/start-registry.sh"

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

# Create systemd service or init script
cat > "${ROOTFS}/etc/init.d/registry" << 'INITEOF'
#!/bin/sh
case "$1" in
  start)
    echo "Starting Docker Registry..."
    /usr/local/bin/start-registry.sh &
    ;;
  stop)
    echo "Stopping Docker Registry..."
    killall registry 2>/dev/null || true
    ;;
  *)
    echo "Usage: $0 {start|stop}"
    exit 1
    ;;
esac
INITEOF
chmod +x "${ROOTFS}/etc/init.d/registry"

# Create fstab
cat > "${ROOTFS}/etc/fstab" << 'FSTABEOF'
/dev/sda1 / ext4 defaults 0 1
proc /proc proc defaults 0 0
sysfs /sys sysfs defaults 0 0
FSTABEOF

# Create resolv.conf
cat > "${ROOTFS}/etc/resolv.conf" << 'RESOLVEOF'
nameserver 8.8.8.8
nameserver 8.8.4.4
RESOLVEOF

echo "Rootfs created"

# Create qcow2 image
QCOW2_FILE="${OUTPUT_DIR}/${VM_NAME}-${VERSION}.qcow2"
echo "Creating qcow2 image..."

if command -v qemu-img >/dev/null 2>&1; then
    qemu-img create -f qcow2 "${QCOW2_FILE}" "${DISK_SIZE}"
    
    # Format with ext4 using guestfish if available, otherwise raw image
    echo "Qcow2 image created: ${QCOW2_FILE}"
else
    echo "WARNING: qemu-img not found. Creating raw image instead..."
    dd if=/dev/zero of="${OUTPUT_DIR}/${VM_NAME}-${VERSION}.img" bs=1G count=10
    QCOW2_FILE="${OUTPUT_DIR}/${VM_NAME}-${VERSION}.img"
fi

# Create VMDK image
VMDK_FILE="${OUTPUT_DIR}/${VM_NAME}-${VERSION}.vmdk"
echo "Creating VMDK image..."

if command -v qemu-img >/dev/null 2>&1; then
    qemu-img convert -O vmdk "${QCOW2_FILE}" "${VMDK_FILE}"
    echo "VMDK image created: ${VMDK_FILE}"
else
    echo "WARNING: qemu-img not found. VMDK creation skipped."
fi

# Create VDI image (VirtualBox)
VDI_FILE="${OUTPUT_DIR}/${VM_NAME}-${VERSION}.vdi"
echo "Creating VDI image..."

if command -v qemu-img >/dev/null 2>&1; then
    qemu-img convert -O vdi "${QCOW2_FILE}" "${VDI_FILE}"
    echo "VDI image created: ${VDI_FILE}"
fi

echo ""
echo "Build complete!"
echo "Output files:"
ls -lh "${OUTPUT_DIR}"

# Create cloud-init configuration
cat > "${OUTPUT_DIR}/cloud-init.yaml" << 'CLOUDINITEOF'
#cloud-config
hostname: docker-registry
users:
  - name: admin
    pass: $6$rounds=4096$random$salt$hash
    groups: sudo, docker
chpasswd:
  list: |
    admin:admin123
  expire: False
runcmd:
  - systemctl enable registry
EOF

echo "Cloud-init config created: ${OUTPUT_DIR}/cloud-init.yaml"
echo "Done!"
