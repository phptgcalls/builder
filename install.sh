#!/usr/bin/env bash

export DEBIAN_FRONTEND=noninteractive

LOG() { printf "\n=> %s\n" "$*"; }
ERR() { printf "\n[ERR] %s\n" "$*" >&2; }

# Require sudo if not root (best-effort)
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; else
    ERR "Not running as root and sudo not found. Some installs may fail."
  fi
fi

# Detect package manager
PKG=""
if command -v apt-get >/dev/null 2>&1; then PKG="apt"; fi
if command -v dnf >/dev/null 2>&1; then PKG="dnf"; fi
if command -v yum >/dev/null 2>&1 && [ -z "$PKG" ]; then PKG="yum"; fi
if command -v pacman >/dev/null 2>&1; then PKG="pacman"; fi
if command -v apk >/dev/null 2>&1; then PKG="apk"; fi
if command -v brew >/dev/null 2>&1; then PKG="brew"; fi
if command -v choco >/dev/null 2>&1; then PKG="choco"; fi

LOG "Detected package manager: ${PKG:-none}"

# Common extension names we want available (composer.json implied)
EXTS=(cli xml gmp zip mbstring curl bcmath intl openssl json dom fileinfo zlib)

install_apt() {
  LOG "apt: update + install prerequisites"
  $SUDO apt-get update -y
  $SUDO apt-get install -y software-properties-common ca-certificates curl wget git unzip build-essential || true

  # Try to add ondrej/php for recent PHP if available
  if ! grep -q "ondrej/php" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null || true; then
    LOG "Adding ondrej/php PPA (best-effort)"
    $SUDO add-apt-repository -y ppa:ondrej/php || true
    $SUDO apt-get update -y || true
  fi

  # prefer php8.4 if available, fallback to php (distro)
  PHP_PKG="php8.4"
  if ! apt-cache show "$PHP_PKG" >/dev/null 2>&1; then
    # try other 8.x then generic php
    for p in php8.5 php8.3 php8.2 php; do
      if apt-cache show "$p" >/dev/null 2>&1; then PHP_PKG="$p"; break; fi
    done
  fi

  LOG "Installing $PHP_PKG + extensions via apt (may include extra packages)"
  PKGS=("$PHP_PKG" "${PHP_PKG}-cli" "${PHP_PKG}-dev")
  for e in "${EXTS[@]}"; do
    PKGS+=("${PHP_PKG}-$e" "php-$e")
  done
  $SUDO apt-get install -y "${PKGS[@]}" || true
  $SUDO apt-get install -y openssl zlib1g zlib1g-dev pkg-config php-pear php-dev || true
}

install_dnf_yum() {
  TOOL="${PKG:-dnf}"
  LOG "$TOOL: install EPEL/Remi (best-effort) + php + extensions"
  $SUDO $TOOL install -y epel-release || true
  # Remi is helpful for newer PHP — try to install it but don't fail if it doesn't
  $SUDO $TOOL install -y https://rpms.remirepo.net/enterprise/remi-release-$(rpm -E %rhel).rpm 2>/dev/null || true

  # Install generic php + common extensions
  PACKS=(php php-cli php-devel php-xml php-gmp php-zip php-mbstring php-curl php-bcmath php-intl)
  $SUDO $TOOL install -y "${PACKS[@]}" || true
}

install_pacman() {
  LOG "pacman: installing php + common extensions"
  $SUDO pacman -Sy --noconfirm php php-pear php-gmp php-xml php-curl php-zip || true
}

install_apk() {
  LOG "apk: installing php8 + extensions"
  $SUDO apk update || true
  $SUDO apk add --no-cache php8 php8-cli php8-phar php8-xml php8-openssl php8-gmp php8-zip php8-curl php8-mbstring build-base git curl || true
}

install_brew() {
  LOG "Homebrew: installing php"
  if ! command -v brew >/dev/null 2>&1; then
    LOG "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || true
    eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || true)" || true
  fi
  # prefer php@8.4 if available
  if brew info php@8.4 >/dev/null 2>&1; then
    brew install php@8.4 || true
    brew link --force --overwrite php@8.4 || true
  else
    brew install php || true
  fi
}

install_choco() {
  ERR "Chocolatey detected. Please run a Windows-native script (PowerShell) or use WSL/Git-Bash. Exiting."
  exit 1
}

# Run installer for detected package manager (best-effort)
case "$PKG" in
  apt) install_apt ;;
  dnf|yum) install_dnf_yum ;;
  pacman) install_pacman ;;
  apk) install_apk ;;
  brew) install_brew ;;
  choco) install_choco ;;
  *) ERR "No supported package manager detected. Please run on Debian/Ubuntu, RHEL/Fedora, Arch, Alpine, or macOS." ; exit 1 ;;
esac

# Verify php exists
if ! command -v php >/dev/null 2>&1; then
  ERR "php not found in PATH after install. Aborting."
  exit 1
fi

PHP_BIN="$(command -v php)"
LOG "Using PHP: $PHP_BIN"
LOG "PHP version: $($PHP_BIN -v | head -n1)"

# Check 64-bit
BITS=$($PHP_BIN -r 'echo PHP_INT_SIZE * 8;' 2>/dev/null || echo "unknown")
if [ "$BITS" != "64" ]; then
  ERR "Detected PHP integer size: $BITS bits. LiveProto requires 64-bit PHP (composer.json). Proceeding but this may fail."
fi

# Check extensions and list missing ones
MISSING=()
for ext in openssl gmp xml zip mbstring curl bcmath intl json dom fileinfo zlib; do
  if ! php -r "exit(extension_loaded('$ext')?0:1);" >/dev/null 2>&1; then
    MISSING+=("$ext")
  fi
done

if [ "${#MISSING[@]}" -ne 0 ]; then
  LOG "Missing PHP extensions: ${MISSING[*]}"
  LOG "Attempted to install common packages earlier — if extensions still missing, install them manually (e.g. php-gmp, php-xml)."
else
  LOG "All common extensions appear present."
fi

# Composer installer (simple)
install_composer() {
  if command -v composer >/dev/null 2>&1; then
    LOG "Composer already installed: $(composer --version 2>/dev/null || true)"
    return 0
  fi

  LOG "Downloading Composer installer..."
  php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" || { ERR "Failed to download composer installer with php"; exit 1; }
  php composer-setup.php --install-dir=/usr/local/bin --filename=composer >/dev/null 2>&1 || \
    php composer-setup.php --install-dir="$HOME/.local/bin" --filename=composer >/dev/null 2>&1 || true
  rm -f composer-setup.php

  if command -v composer >/dev/null 2>&1; then
    LOG "Composer installed: $(composer --version 2>/dev/null || true)"
  else
    ERR "Composer not found after install. Add ~/.local/bin or /usr/local/bin to PATH or move composer.phar into PATH."
  fi
}

install_composer

if ! command -v composer >/dev/null 2>&1; then
  ERR "Composer missing — cannot continue to composer install step."
  exit 1
fi

# Create demo project and require taknone/liveproto
DEMO="$HOME/liveproto-demo"
mkdir -p "$DEMO"
cd "$DEMO"

if [ ! -f composer.json ]; then
  LOG "Initializing composer project in $DEMO"
  composer init --no-interaction --name="liveproto/demo" --description="LiveProto demo" >/dev/null 2>&1 || true
fi

LOG "Running: composer require taknone/liveproto --no-interaction --prefer-dist"
composer require taknone/liveproto --no-interaction --prefer-dist || {
  ERR "composer require failed. You can retry manually inside $DEMO."
}

LOG "Summary:"
LOG " - PHP: $($PHP_BIN -v | head -n1)"
LOG " - Composer: $(composer --version 2>/dev/null || echo 'not found')"
if [ -d "$DEMO/vendor/taknone/liveproto" ]; then
  LOG " - LiveProto installed at: $DEMO/vendor/taknone/liveproto"
else
  ERR " - LiveProto not found in vendor (composer require may have failed)."
fi

LOG "Done. If anything failed, re-run the script as root or consult the error messages shown above."

exit 0
