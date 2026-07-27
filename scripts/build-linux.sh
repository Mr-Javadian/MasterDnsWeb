#!/usr/bin/env bash
set -euo pipefail

# دریافت معماری از آرگومان خط فرمان (پیش‌فرض: amd64)
ARCH="${1:-amd64}"

# ── تنظیم متغیرهای ساخت بر اساس معماری ──
case "$ARCH" in
    amd64)
        OUTPUT_NAME="MasterDnsWeb-linux-amd64"
        ;;
    armv7)
        OUTPUT_NAME="MasterDnsWeb-linux-armv7"
        # تنظیم متغیرهای محیطی برای کراس-کامپایل
        export CC=arm-linux-gnueabihf-gcc
        export CXX=arm-linux-gnueabihf-g++
        export AR=arm-linux-gnueabihf-ar
        ;;
    *)
        echo "❌ Unsupported architecture: $ARCH"
        echo "   Supported: amd64, armv7"
        exit 1
        ;;
esac

echo "🔨 Building for $ARCH..."

# ── مراحل ساخت ──
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR/frontend"
echo "==> Installing Node dependencies..."
npm install
echo "==> Generating static frontend..."
npm run generate
cd "$ROOT_DIR"
echo "==> Copying static output to backend..."
node scripts/copy-static.mjs

echo "==> Setting up Python venv..."
python3 -m venv .buildenv
source .buildenv/bin/activate
echo "==> Installing Python dependencies..."
pip install --upgrade pip
pip install -r backend/requirements.txt
pip install pyinstaller

echo "==> Building binary with PyInstaller..."
# استفاده از متغیرهای محیطی برای کراس-کامپایل
pyinstaller build.spec --distpath dist --workpath build_tmp --clean -y

echo "==> Cleaning up build artifacts..."
rm -rf build_tmp .buildenv

BINARY="dist/MasterDnsWeb"
if [ ! -f "$BINARY" ]; then
    echo "ERROR: Build failed – binary not found at $BINARY"
    exit 1
fi
chmod +x "$BINARY"

# ── مونتاژ پوشه نهایی ──
RELEASE_NAME="MasterDnsWeb"
RELEASE_DIR="dist/release/$RELEASE_NAME"
RELEASE_ARCHIVE="dist/${OUTPUT_NAME}.tar.gz"

rm -rf "dist/release"
mkdir -p "$RELEASE_DIR"

cp "$BINARY" "$RELEASE_DIR/MasterDnsWeb"
chmod +x "$RELEASE_DIR/MasterDnsWeb"

# ── (اختیاری) کپی کردن MasterDnsVPN اگر موجود باشد ──
if [ -f "$ROOT_DIR/backend/bin/MasterDnsVPN" ]; then
    cp "$ROOT_DIR/backend/bin/MasterDnsVPN" "$RELEASE_DIR/MasterDnsVPN"
    chmod +x "$RELEASE_DIR/MasterDnsVPN"
    echo "==> Included MasterDnsVPN from: backend/bin/MasterDnsVPN"
fi

# ── ایجاد فایل .env ──
GENERATED_SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
cat > "$RELEASE_DIR/.env" << EOF
ADMIN_USERNAME=admin
ADMIN_PASSWORD=changeme
SECRET_KEY=${GENERATED_SECRET}
HOST=0.0.0.0
PORT=8000
COOKIE_SECURE=false
MASTERVPN_SERVICE_USER=root
MASTERVPN_SERVICE_RESTART=always
MASTERVPN_SERVICE_RESTART_SEC=5
EOF

# ── فشرده‌سازی ──
tar -czf "$RELEASE_ARCHIVE" -C "dist/release" "$RELEASE_NAME"
rm -rf "dist/release"

ARCHIVE_SIZE=$(du -h "$RELEASE_ARCHIVE" | cut -f1)
echo ""
echo "✅ Build complete: $RELEASE_ARCHIVE ($ARCHIVE_SIZE)"
echo ""
echo "📥 Deploy:"
echo "   tar -xzf ${OUTPUT_NAME}.tar.gz"
echo "   cd MasterDnsWeb"
echo "   nano .env   # set ADMIN_PASSWORD"
echo "   sudo ./MasterDnsWeb"
