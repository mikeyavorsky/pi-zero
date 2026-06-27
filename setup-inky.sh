#!/usr/bin/env bash
#
# setup-inky.sh — Install the Pimoroni Inky library (via uv) on a Raspberry Pi
# Zero 2 W and draw an example on an Inky pHAT V2 (Yellow).
#
# Usage:
#   ./setup-inky.sh              # run on your Mac: SSHes into `pizero` and runs remotely
#   ./setup-inky.sh --remote     # run this *on the Pi* (e.g. after scp'ing it over)
#
# The script is self-bootstrapping: when run without --remote it pipes itself
# over SSH to the host `pizero` and re-invokes itself there with --remote.
#
# Assumptions for the SSH path:
#   * You can `ssh pizero` (configure ~/.ssh/config Host pizero, or it resolves
#     via mDNS as pizero.local — adjust SSH_HOST below if needed).
#   * The Pi user has passwordless sudo (default on Raspberry Pi OS). If not,
#     scp the script over and run `./setup-inky.sh --remote` interactively.

set -euo pipefail

SSH_HOST="${SSH_HOST:-pizero}"

# ---------------------------------------------------------------------------
# Local side: ship ourselves to the Pi and run there.
# ---------------------------------------------------------------------------
if [[ "${1:-}" != "--remote" ]]; then
  echo ">>> Connecting to ${SSH_HOST} and running the installer remotely..."
  # Pipe ourselves over stdin and re-invoke with --remote. We can't allocate a
  # tty here (stdin is the script), so this relies on passwordless sudo on the
  # Pi — the default on Raspberry Pi OS.
  set +e
  ssh -o ConnectTimeout=10 "${SSH_HOST}" 'bash -s -- --remote' < "$0"
  rc=$?
  set -e
  if [[ $rc -eq 255 ]]; then
    cat <<EOF
!!! Could not SSH to '${SSH_HOST}'.
    Copy this script to the Pi and run it there instead:

        scp "$0" ${SSH_HOST}:~/setup-inky.sh
        ssh ${SSH_HOST}
        ./setup-inky.sh --remote

    (Or set SSH_HOST=user@host.local and re-run.)
EOF
    exit 1
  elif [[ $rc -ne 0 ]]; then
    echo ">>> Remote install exited with status $rc — see output above."
    exit $rc
  fi
  echo ">>> Done. Check the Inky pHAT — it should now show the example image."
  exit 0
fi

# ===========================================================================
# Remote side: everything below runs ON the Raspberry Pi.
# ===========================================================================
echo "=== Running on $(hostname) — $(uname -m) ==="

PROJECT_DIR="$HOME/inky-demo"

# --- 1. Enable SPI + I2C (Inky talks SPI; auto-detect reads board EEPROM over I2C)
echo "--- Enabling SPI and I2C interfaces..."
if command -v raspi-config >/dev/null 2>&1; then
  sudo raspi-config nonint do_spi 0 || true
  sudo raspi-config nonint do_i2c 0 || true
fi

# We pin inky 1.5.0 (see install step below), which uses *hardware* chip-select
# and opens /dev/spidev0.0 directly — so we need the DEFAULT SPI config. Remove
# any 'dtoverlay=spi0-0cs' left over from earlier attempts: it deletes the
# spidev0.0 node, and on a Pi Zero W the kernel doesn't honour it anyway (the
# BCM2835 driver re-claims the CS pin — raspberrypi/linux#5835).
NEEDS_REBOOT=0
BOOT_CONFIG=/boot/firmware/config.txt
[ -f "$BOOT_CONFIG" ] || BOOT_CONFIG=/boot/config.txt
if grep -q '^dtoverlay=spi0-0cs' "$BOOT_CONFIG"; then
  echo "--- Removing 'dtoverlay=spi0-0cs' from ${BOOT_CONFIG} (restores /dev/spidev0.0)..."
  sudo sed -i '/^dtoverlay=spi0-0cs$/d' "$BOOT_CONFIG"
  NEEDS_REBOOT=1
fi

# --- 2. System prerequisites (build deps, fonts, SPI tools)
echo "--- Installing system packages..."
sudo apt-get update

# libtiff package name differs by Debian release (Bullseye=libtiff5, Bookworm=libtiff6).
if apt-cache show libtiff6 >/dev/null 2>&1; then
  TIFF_PKG=libtiff6
else
  TIFF_PKG=libtiff5
fi

sudo apt-get install -y --no-install-recommends \
  curl ca-certificates \
  python3-dev python3-venv python3-pip \
  build-essential \
  libjpeg-dev zlib1g-dev libopenjp2-7 "${TIFF_PKG}" libopenblas0 \
  i2c-tools \
  fonts-dejavu-core \
  python3-numpy python3-pil python3-spidev python3-smbus python3-rpi.gpio

# --- 3. Install uv (per-user, no root needed)
# Put ~/.local/bin on PATH *before* the check, or a fresh SSH session won't see
# an already-installed uv and would reinstall it every run.
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
if command -v uv >/dev/null 2>&1; then
  echo "--- uv already installed ($(uv --version))"
else
  echo "--- Installing uv..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  hash -r
fi

# --- 4. Create a venv (system Python) and install Inky with uv
echo "--- Setting up project at ${PROJECT_DIR}..."
mkdir -p "${PROJECT_DIR}"
cd "${PROJECT_DIR}"

# IMPORTANT: this is 32-bit Raspberry Pi OS (uname reports armv6l), for which
# there are NO uv-managed CPython builds. So we build the venv from the SYSTEM
# python3 (3.9 on Bullseye) and only use uv as the fast installer/resolver.
SYS_PY="$(command -v python3)"

# piwheels serves prebuilt ARM wheels for anything that does need fetching.
export UV_EXTRA_INDEX_URL="https://www.piwheels.org/simple"
export UV_INDEX_STRATEGY="unsafe-best-match"

VENV_PY="${PROJECT_DIR}/.venv/bin/python"

# Only create the venv if it isn't there already. --system-site-packages lets it
# see apt's prebuilt python3-numpy / python3-pil / python3-spidev (compiling
# those from source on this single-core armv6 box takes ages).
if [[ ! -x "${VENV_PY}" ]]; then
  echo "    Creating venv from system Python: ${SYS_PY} ($("${SYS_PY}" --version))"
  uv venv --system-site-packages --python "${SYS_PY}" --python-preference only-system
else
  echo "    Reusing existing venv at ${PROJECT_DIR}/.venv"
fi

# Pin inky 1.5.0: it uses hardware chip-select + RPi.GPIO (no gpiod), so it
# avoids the Pi Zero W SPI-CS kernel bug that breaks inky 2.x. Its deps
# (numpy/smbus2/spidev/RPi.GPIO) are all apt-provided, so nothing compiles.
INKY_VERSION="1.5.0"
if "${VENV_PY}" -c "import inky,sys; sys.exit(0 if inky.__version__=='${INKY_VERSION}' else 1)" >/dev/null 2>&1; then
  echo "--- inky ${INKY_VERSION} already installed (skipping)"
else
  echo "--- Installing inky ${INKY_VERSION} (numpy/Pillow/spidev/RPi.GPIO provided by apt)..."
  uv pip install "inky[rpi]==${INKY_VERSION}"
fi

# --- 5. Write the example program
echo "--- Writing example..."
cat > example.py <<'PYEOF'
#!/usr/bin/env python3
"""Draw a simple example on an Inky pHAT V2 (Yellow)."""
from inky.auto import auto
from PIL import Image, ImageDraw, ImageFont

# V2 boards carry an EEPROM, so auto() detects the exact display without asking.
inky = auto(ask_user=False, verbose=True)
inky.set_border(inky.YELLOW)

img = Image.new("P", (inky.width, inky.height))
draw = ImageDraw.Draw(img)

font_path = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
big = ImageFont.truetype(font_path, 24)
small = ImageFont.truetype(font_path, 14)

# Yellow background block with black text + a yellow accent line.
draw.rectangle((0, 0, inky.width, inky.height), fill=inky.WHITE)
draw.text((8, 8), "Hello, Inky!", inky.BLACK, font=big)
draw.text((8, 44), "pHAT V2 — Yellow", inky.YELLOW, font=small)
draw.text((8, 66), "Installed with uv", inky.BLACK, font=small)
draw.line((8, 88, inky.width - 8, 88), fill=inky.YELLOW, width=3)

inky.set_image(img)
inky.show()
print("Image sent to the Inky pHAT.")
PYEOF

# --- 6. Reboot if we just changed the boot overlay, otherwise run the example
if [[ "${NEEDS_REBOOT}" -eq 1 ]]; then
  cat <<'EOF'

=== Added the spi0-0cs overlay; a reboot is required to free the SPI CS pin. ===
    The Pi will reboot now. Once it's back (~30s), re-run ./setup-inky.sh
    and it will go straight to displaying the example.
EOF
  # Reboot in the background after a short delay so this script can exit 0 and
  # the SSH connection closes cleanly before the box goes down.
  sudo nohup bash -c 'sleep 3; reboot' >/dev/null 2>&1 &
  exit 0
fi

echo "--- Displaying example on the Inky pHAT..."
"${VENV_PY}" example.py

echo "=== Finished. The Inky pHAT should now show the example. ==="
echo "    Re-run anytime with:  cd ${PROJECT_DIR} && .venv/bin/python example.py"
