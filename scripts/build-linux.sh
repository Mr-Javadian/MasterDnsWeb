#!/usr/bin/env bash
set -euo pipefail

# دریافت معماری از آرگومان خط فرمان (پیش‌فرض: amd64)
ARCH="${1:-amd64}"

# ── تنظیم متغیرهای ساخت بر اساس معماری ──
case "$ARCH" in
    amd64)
        PYINSTALLER_IMAGE="quay.io/pypa/manylinux2014_x86_64:latest"
        OUTPUT_NAME="MasterDnsWeb-linux-amd64"
        PLATFORM="x86_64"
        ;;
    armv7)
        PYINSTALLER_IMAGE="quay.io/pypa/manylinux2014_armv7l:latest"
        OUTPUT_NAME="MasterDnsWeb-linux-armv7"
        PLATFORM="armv7l"
        ;;
    *)
        echo "❌ Unsupported architecture: $ARCH"
        echo "   Supported: amd64, armv7"
        exit 1
        ;;
esac

echo "🔨 Building for $ARCH (platform: $PLATFORM)..."

# ── ساخت درون کانتینر Docker برای کراس-کامپایل ──
docker run --rm \
    -v "$(pwd):/workspace" \
    -w /workspace \
    "$PYINSTALLER_IMAGE" \
    bash -c "
        set -euo pipefail

        echo '==> Installing Node dependencies...'
        cd frontend
        npm install
        echo '==> Generating static frontend...'
        npm run generate
        cd ..

        echo '==> Copying static output to backend...'
        node scripts/copy-static.mjs

        echo '==> Setting up Python venv...'
        python3 -m venv .buildenv
        source .buildenv/bin/activate

        echo '==> Installing Python dependencies...'
        pip install --upgrade pip
        pip install -r backend/requirements.txt
        pip install pyinstaller

        echo '==> Building binary with PyInstaller...'
        pyinstaller build.spec --distpath dist --workpath build_tmp --clean -y

        echo '==> Cleaning up build artifacts...'
        rm -rf build_tmp .buildenv

        BINARY='dist/MasterDnsWeb'
        if [ ! -f \"\$BINARY\" ]; then
            echo 'ERROR: Build failed – binary not found at \$BINARY'
            exit 1
        fi
        chmod +x \"\$BINARY\"

        # ── Locate MasterDnsVPN binary ──
        VPN_BINARY=''
        if [ -f 'backend/bin/MasterDnsVPN' ]; then
            VPN_BINARY='backend/bin/MasterDnsVPN'
        elif [ -n \"\${MASTERDNSVPN_BINARY:-}\" ] && [ -f \"\${MASTERDNSVPN_BINARY}\" ]; then
            VPN_BINARY=\"\${MASTERDNSVPN_BINARY}\"
        fi

        # ── Assemble release folder ──
        RELEASE_NAME='MasterDnsWeb'
        RELEASE_DIR='dist/release/\$RELEASE_NAME'
        RELEASE_ARCHIVE='dist/${OUTPUT_NAME}.tar.gz'

        rm -rf dist/release
        mkdir -p \"\$RELEASE_DIR\"

        cp \"\$BINARY\" \"\$RELEASE_DIR/MasterDnsWeb\"
        chmod +x \"\$RELEASE_DIR/MasterDnsWeb\"

        if [ -n \"\$VPN_BINARY\" ]; then
            cp \"\$VPN_BINARY\" \"\$RELEASE_DIR/MasterDnsVPN\"
            chmod +x \"\$RELEASE_DIR/MasterDnsVPN\"
            echo '==> Included MasterDnsVPN from: '\$VPN_BINARY
        else
            echo ''
            echo 'WARNING: MasterDnsVPN binary not found.'
            echo '  Place it at backend/bin/MasterDnsVPN, or set the MASTERDNSVPN_BINARY env var.'
            echo '  The release archive will be created without it – add it manually before deploying.'
            echo ''
        fi

        # Generate a random secret key for the .env template
        GENERATED_SECRET=\$(python3 -c 'import secrets; print(secrets.token_hex(32))')

        cat > \"\$RELEASE_DIR/.env\" << EOF
# MasterDnsWeb — Configuration
# Edit this file, then run:  sudo ./MasterDnsWeb
#
# MasterDnsWeb MUST run as root (or with sudo) to manage systemd services.

# ── Web panel access ──────────────────────────────────────
ADMIN_USERNAME=admin
ADMIN_PASSWORD=changeme

# Random secret used to sign login sessions.
# A unique value has been generated for you — do not share it.
SECRET_KEY=\${GENERATED_SECRET}

# ── Network ───────────────────────────────────────────────
HOST=0.0.0.0
PORT=8000

# Set to true if you are using HTTPS (e.g. behind nginx with SSL)
COOKIE_SECURE=false

# ── Service settings ──────────────────────────────────────
MASTERVPN_SERVICE_USER=root
MASTERVPN_SERVICE_RESTART=always
MASTERVPN_SERVICE_RESTART_SEC=5
# Override only if MasterDnsVPN is not in the same folder as MasterDnsWeb:
# MASTERVPN_SERVICE_EXEC_START=/path/to/MasterDnsVPN
EOF

        tar -czf \"\$RELEASE_ARCHIVE\" -C dist/release \"\$RELEASE_NAME\"
        rm -rf dist/release

        ARCHIVE_SIZE=\$(du -h \"\$RELEASE_ARCHIVE\" | cut -f1)
        echo ''
        echo 'Release archive: \$RELEASE_ARCHIVE (\$ARCHIVE_SIZE)'
        echo ''
        echo 'Deploy:'
        echo '  tar -xzf ${OUTPUT_NAME}.tar.gz'
        echo '  cd MasterDnsWeb'
        echo '  nano .env              # set ADMIN_PASSWORD — everything else has safe defaults'
        echo '  sudo ./MasterDnsWeb    # must run as root to manage systemd services'
        echo ''
        echo '  Folder layout after first run:'
        echo '    MasterDnsWeb/'
        echo '      MasterDnsWeb   ← web panel binary'
        echo '      MasterDnsVPN   ← VPN client binary'
        echo '      .env           ← your config'
        echo '      data/          ← instance profiles (auto-created)'
        echo '      runtime/       ← per-instance working dirs (auto-created)'
    "

echo "✅ Build for $ARCH completed successfully!"
