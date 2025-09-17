#!/usr/bin/env bash
































LOG(){
printf "\n=> %s\n" "$*";
}

ERR(){
printf "\n[ERROR] %s\n" "$*" >&2;
}













# prefer sudo when not root
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; else
    ERR "Not root and sudo not found — some install steps may fail."
  fi
fi

# detect package manager
PKG=""
if command -v apt-get >/dev/null 2>&1; then PKG="apt"; fi
if command -v dnf >/dev/null 2>&1; then PKG="dnf"; fi
if command -v yum >/dev/null 2>&1 && [ -z "$PKG" ]; then PKG="yum"; fi
if command -v pacman >/dev/null 2>&1; then PKG="pacman"; fi
if command -v apk >/dev/null 2>&1; then PKG="apk"; fi
if command -v brew >/dev/null 2>&1; then PKG="brew"; fi

LOG "Package manager detected: ${PKG:-none}"

install_apt(){
  LOG "apt: updating and installing common packages..."
  $SUDO apt-get update -y || true
  $SUDO apt-get install -y software-properties-common ca-certificates curl wget git unzip || true
  # Add ondrej PPA if available for newer php
  if ! grep -q "ondrej/php" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null || true; then
    LOG "Adding ondrej/php PPA (if supported)..."
    $SUDO add-apt-repository -y ppa:ondrej/php >/dev/null 2>&1 || true
    $SUDO apt-get update -y || true
  fi
  PHP_PKG="php8.4"
  if ! apt-cache show "$PHP_PKG" >/dev/null 2>&1; then
    for p in php8.5 php8.3 php8.2 php; do
      if apt-cache show "$p" >/dev/null 2>&1; then PHP_PKG="$p"; break; fi
    done
  fi
  LOG "Installing $PHP_PKG and common extensions..."
  $SUDO apt-get install -y "${PHP_PKG}" "${PHP_PKG}-cli" "${PHP_PKG}-dev" \
    "${PHP_PKG}-xml" "${PHP_PKG}-gmp" "${PHP_PKG}-zip" "${PHP_PKG}-mbstring" \
    "${PHP_PKG}-curl" "${PHP_PKG}-bcmath" "${PHP_PKG}-intl" || true
}

install_dnf(){
  TOOL="${PKG:-dnf}"
  LOG "$TOOL: installing common packages..."
  $SUDO $TOOL install -y epel-release curl wget git || true
  # Try to install php and common extensions
  $SUDO $TOOL install -y php php-cli php-xml php-gmp php-zip php-mbstring php-curl php-bcmath php-intl || true
}

install_pacman(){
  LOG "pacman: installing php + common packages"
  $SUDO pacman -Sy --noconfirm php php-pear php-gmp php-xml php-curl php-zip || true
}

install_apk(){
  LOG "apk: installing php8 + common packages"
  $SUDO apk update || true
  $SUDO apk add --no-cache php8 php8-cli php8-phar php8-xml php8-openssl php8-gmp php8-zip php8-curl php8-mbstring git curl || true
}

install_brew(){
  LOG "Homebrew: installing php"
  if ! command -v brew >/dev/null 2>&1; then
    LOG "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || true
    eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || true)" || true
  fi
  if brew info php@8.4 >/dev/null 2>&1; then
    brew install php@8.4 || true
    brew link --force --overwrite php@8.4 || true
  else
    brew install php || true
  fi
}

case "$PKG" in
  apt) install_apt ;;
  dnf|yum) install_dnf ;;
  pacman) install_pacman ;;
  apk) install_apk ;;
  brew) install_brew ;;
  *) ERR "Unsupported/undetected package manager. Run this on Debian/Ubuntu, RHEL/Fedora, Arch, Alpine, or macOS." ; exit 1 ;;
esac

# verify php
if ! command -v php >/dev/null 2>&1; then
  ERR "php not found after package install. Aborting."
  exit 1
fi

PHP_BIN="$(command -v php)"
LOG "PHP: $($PHP_BIN -v | head -n1)"
BITS=$($PHP_BIN -r 'echo PHP_INT_SIZE*8;' 2>/dev/null || echo "unknown")
if [ "$BITS" != "64" ]; then
  ERR "Detected PHP integer size: $BITS bits. LiveProto expects 64-bit PHP. Continue at your own risk."
fi

# check extensions (best-effort)
NEEDED=(openssl gmp xml zip mbstring curl bcmath intl json dom fileinfo zlib)
MISSING=()
for e in "${NEEDED[@]}"; do
  if ! php -r "exit(extension_loaded('$e')?0:1);" >/dev/null 2>&1; then
    MISSING+=("$e")
  fi
done
if [ ${#MISSING[@]} -ne 0 ]; then
  LOG "Missing extensions: ${MISSING[*]}. Try installing distro packages (eg. php-gmp, php-xml) and re-run."
else
  LOG "All common extensions present."
fi

# composer installation (simple)
install_composer(){
  if command -v composer >/dev/null 2>&1; then
    LOG "Composer present: $(composer --version 2>/dev/null || true)"
    return 0
  fi
  LOG "Installing Composer..."
  php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" || { ERR "Failed to download composer installer"; exit 1; }
  $SUDO php composer-setup.php --install-dir=/usr/local/bin --filename=composer >/dev/null 2>&1 || \
    php composer-setup.php --install-dir="$HOME/.local/bin" --filename=composer >/dev/null 2>&1 || true
  rm -f composer-setup.php
  if ! command -v composer >/dev/null 2>&1; then
    ERR "Composer not in PATH. Add /usr/local/bin or $HOME/.local/bin to PATH or move composer.phar."
  fi
}
install_composer

if ! command -v composer >/dev/null 2>&1; then
  ERR "Composer missing. Aborting composer steps."
  exit 1
fi

# composer require library in demo dir
DEMO="$HOME/liveproto-demo"
mkdir -p "$DEMO"
cd "$DEMO"
if [ ! -f composer.json ]; then
  LOG "Initializing composer project..."
  composer init --no-interaction --name="liveproto/demo" --description="LiveProto demo" >/dev/null 2>&1 || true
fi

LOG "Running: composer require taknone/liveproto"
composer require taknone/liveproto --no-interaction --prefer-dist || {
  ERR "composer require failed. Inspect output and retry inside $DEMO."
}

LOG "Summary: PHP: $($PHP_BIN -v | head -n1); Composer: $(composer --version 2>/dev/null || echo 'not found')"
if [ -d "$DEMO/vendor/taknone/liveproto" ]; then
  LOG "LiveProto installed at: $DEMO/vendor/taknone/liveproto"
else
  ERR "LiveProto not found in vendor (composer may have failed)."
fi

LOG "Done."
exit 0


