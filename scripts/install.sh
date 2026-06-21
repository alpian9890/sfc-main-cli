#!/usr/bin/env sh
set -eu

REPO="${SEOFAST_REPO:-alpian9890/sfc-main-cli}"
VERSION="${SEOFAST_VERSION:-latest}"
INSTALL_DIR="${SEOFAST_INSTALL_DIR:-/usr/local/bin}"
BIN_NAME="seofast"

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif need_cmd sudo; then
    sudo "$@"
  else
    echo "Error: install ke ${INSTALL_DIR} butuh root. Jalankan sebagai root atau install sudo." >&2
    exit 1
  fi
}

systemd_available() {
  need_cmd systemctl || return 1
  [ -d /run/systemd/system ] || return 1
  return 0
}

cleanup_legacy_units() {
  if ! systemd_available; then
    return 0
  fi
  as_root systemctl disable --now seofast-telegram.timer seofast-telegram.service >/dev/null 2>&1 || true
  as_root rm -f /etc/systemd/system/seofast-telegram.timer /etc/systemd/system/seofast-telegram.service
  as_root systemctl daemon-reload >/dev/null 2>&1 || true
  as_root systemctl reset-failed >/dev/null 2>&1 || true
}

detect_arch() {
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)
      echo "x64"
      ;;
    aarch64|arm64)
      echo "arm64"
      ;;
    *)
      echo "Error: arsitektur tidak didukung: $arch" >&2
      exit 1
      ;;
  esac
}

download() {
  url="$1"
  output="$2"
  echo "URL: ${url}"
  if need_cmd curl; then
    curl -fL --progress-bar "$url" -o "$output"
  elif need_cmd wget; then
    if wget --help 2>/dev/null | grep -q -- '--show-progress'; then
      wget --show-progress -O "$output" "$url"
    else
      wget -O "$output" "$url"
    fi
  else
    echo "Error: curl atau wget belum tersedia." >&2
    exit 1
  fi
}

ask_yes_no() {
  prompt="$1"
  default="${2:-n}"
  if [ "$default" = "y" ]; then
    suffix="[Y/n]"
  else
    suffix="[y/N]"
  fi
  if [ ! -r /dev/tty ]; then
    return 1
  fi
  printf "%s %s " "$prompt" "$suffix" >/dev/tty
  read -r answer </dev/tty || answer=""
  answer="$(printf "%s" "$answer" | tr '[:upper:]' '[:lower:]')"
  if [ -z "$answer" ]; then
    answer="$default"
  fi
  [ "$answer" = "y" ] || [ "$answer" = "yes" ]
}

ask_menu_choice() {
  prompt="$1"
  valid="$2"
  default="${3:-}"
  if [ ! -r /dev/tty ]; then
    if [ -n "$default" ]; then
      echo "$default"
      return 0
    fi
    return 1
  fi
  while true; do
    printf "%s" "$prompt" >/dev/tty
    read -r answer </dev/tty || answer=""
    if [ -z "$answer" ] && [ -n "$default" ]; then
      answer="$default"
    fi
    case " $valid " in
      *" $answer "*)
        echo "$answer"
        return 0
        ;;
    esac
    echo "Input tidak valid. Pilih salah satu: ${valid}" >/dev/tty
  done
}

seofast_config_dir() {
  if [ -n "${SEOFAST_HOME:-}" ]; then
    case "$SEOFAST_HOME" in
      "~"|"~/"*) echo "${HOME}${SEOFAST_HOME#\~}" ;;
      *) echo "$SEOFAST_HOME" ;;
    esac
  elif [ -n "${XDG_CONFIG_HOME:-}" ]; then
    echo "${XDG_CONFIG_HOME}/seofast-chromium-cli"
  else
    echo "${HOME}/.config/seofast-chromium-cli"
  fi
}

json_string_value() {
  file="$1"
  key="$2"
  [ -f "$file" ] || return 0
  sed -n \
    -e "s/^[[:space:]]*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\"[[:space:]]*,\{0,1\}[[:space:]]*$/\1/p" \
    -e "s/^[[:space:]]*\"${key}\"[[:space:]]*:[[:space:]]*\([^,}][^,}]*\)[[:space:]]*,\{0,1\}[[:space:]]*$/\1/p" \
    "$file" | head -n 1
}

mask_secret_value() {
  value="$1"
  if [ -z "$value" ]; then
    echo "-"
    return 0
  fi
  if [ "${#value}" -le 8 ]; then
    echo "********"
    return 0
  fi
  prefix="$(printf "%s" "$value" | cut -c 1-4)"
  suffix="$(printf "%s" "$value" | awk '{ print substr($0, length($0) - 3) }')"
  echo "${prefix}...${suffix}"
}

setup_credentials_wizard() {
  echo
  echo "Siapkan credentials seofast?"
  echo "1. Ya (Siapkan sekarang)"
  echo "2. Nanti saja"
  choice="$(ask_menu_choice "Pilihan [1-2]: " "1 2" "2")"
  if [ "$choice" = "1" ]; then
    "${INSTALL_DIR}/${BIN_NAME}" credentials
    echo "Seofast credentials ✅"
  else
    echo "Setup credentials dilewati. Kamu bisa setup nanti menggunakan perintah: seofast credentials"
  fi
}

setup_gmail_wizard() {
  echo
  echo "Siapkan google email untuk payload?"
  "${INSTALL_DIR}/${BIN_NAME}" gmail
}

setup_devtools_wizard() {
  echo
  echo "Siapkan DevTools Chromium?"
  echo "1. Off"
  echo "2. Local"
  echo "3. Public"
  choice="$(ask_menu_choice "Pilihan [1-3]: " "1 2 3" "1")"
  case "$choice" in
    1)
      "${INSTALL_DIR}/${BIN_NAME}" devtools off
      ;;
    2)
      "${INSTALL_DIR}/${BIN_NAME}" devtools local
      ;;
    3)
      "${INSTALL_DIR}/${BIN_NAME}" devtools public
      ;;
  esac
}

setup_player_wizard() {
  echo
  echo "Pilih browser player YouTube:"
  echo "1. chrome-headless-shell (ringan, direkomendasikan)"
  echo "2. chromium (fallback/browser sistem)"
  choice="$(ask_menu_choice "Pilihan [1-2]: " "1 2" "1")"
  case "$choice" in
    1)
      if install_chrome_headless_shell; then
        "${INSTALL_DIR}/${BIN_NAME}" player chrome-headless-shell
      else
        echo "PERINGATAN: chrome-headless-shell gagal dipasang, mencoba Chromium." >&2
        install_chromium || true
        "${INSTALL_DIR}/${BIN_NAME}" player chromium
      fi
      ;;
    2)
      install_chromium || true
      "${INSTALL_DIR}/${BIN_NAME}" player chromium
      ;;
  esac
}

print_setup_summary() {
  cfg_dir="$(seofast_config_dir)"
  telegram_file="${cfg_dir}/telegram.json"
  credentials_file="${cfg_dir}/credentials.json"
  gmail_file="${cfg_dir}/gmail.json"
  devtools_file="${cfg_dir}/devtools.json"
  player_file="${cfg_dir}/player.json"

  echo
  echo "Ringkasan setup:"
  echo "Config dir: ${cfg_dir}"

  if [ -f "$telegram_file" ]; then
    bot_token="$(json_string_value "$telegram_file" "bot_token")"
    notify_time="$(json_string_value "$telegram_file" "time")"
    notify_timezone="$(json_string_value "$telegram_file" "timezone")"
    scheduler="$(json_string_value "$telegram_file" "scheduler")"
    echo "Telegram BOT_TOKEN: $(mask_secret_value "$bot_token")"
    echo "Telegram file: ${telegram_file}"
    login_chat_id="$(json_string_value "$telegram_file" "login_chat_id")"
    login_thread_id="$(json_string_value "$telegram_file" "login_thread_id")"
    earnings_chat_id="$(json_string_value "$telegram_file" "earnings_chat_id")"
    earnings_thread_id="$(json_string_value "$telegram_file" "earnings_thread_id")"
    log_chat_id="$(json_string_value "$telegram_file" "log_chat_id")"
    log_thread_id="$(json_string_value "$telegram_file" "log_thread_id")"
    echo "Login target: ${login_chat_id:-"-"}${login_thread_id:+ / thread ${login_thread_id}}"
    echo "Earnings target: ${earnings_chat_id:-"-"}${earnings_thread_id:+ / thread ${earnings_thread_id}}"
    echo "Log target: ${log_chat_id:-"-"}${log_thread_id:+ / thread ${log_thread_id}}"
    echo "Jadwal notifikasi: ${notify_time:-06:00} ${notify_timezone:-Asia/Jakarta}"
    echo "Scheduler notifikasi: ${scheduler:-manual}"
  else
    echo "Telegram: belum diset"
    echo "Telegram file: ${telegram_file}"
  fi

  if [ -f "$credentials_file" ]; then
    email="$(json_string_value "$credentials_file" "email")"
    password="$(json_string_value "$credentials_file" "password")"
    echo "Credentials seofast: tersedia"
    echo "Credentials email: ${email:-"-"}"
    echo "Credentials password: $(mask_secret_value "$password")"
    echo "Credentials file: ${credentials_file}"
  else
    echo "Credentials seofast: belum diset"
    echo "Credentials file: ${credentials_file}"
  fi

  if [ -f "$gmail_file" ]; then
    google_email="$(json_string_value "$gmail_file" "google_email")"
    echo "google_email: ${google_email:-"-"}"
    echo "Gmail file: ${gmail_file}"
  else
    fallback_email="-"
    if [ -f "$credentials_file" ]; then
      fallback_email="$(json_string_value "$credentials_file" "email")"
    fi
    echo "google_email: fallback dari email login/credentials (${fallback_email:-"-"})"
    echo "Gmail file: ${gmail_file}"
  fi

  if [ -f "$devtools_file" ]; then
    devtools_mode="$(json_string_value "$devtools_file" "mode")"
    devtools_port="$(json_string_value "$devtools_file" "port")"
    devtools_bind="$(json_string_value "$devtools_file" "bind")"
    devtools_host="$(json_string_value "$devtools_file" "public_host")"
    echo "DevTools: ${devtools_mode:-off}"
    echo "DevTools port: ${devtools_port:-9222}"
    echo "DevTools bind: ${devtools_bind:-127.0.0.1}"
    echo "DevTools public host: ${devtools_host:-127.0.0.1}"
    echo "DevTools file: ${devtools_file}"
  else
    echo "DevTools: off"
    echo "DevTools file: ${devtools_file}"
  fi

  if [ -f "$player_file" ]; then
    player_browser="$(json_string_value "$player_file" "browser")"
    player_path="$(json_string_value "$player_file" "path")"
    echo "Player browser: ${player_browser:-"-"}"
    echo "Player path: ${player_path:-"-"}"
    echo "Player file: ${player_file}"
  else
    echo "Player browser: default chrome-headless-shell"
    echo "Player file: ${player_file}"
  fi
}

find_chrome_headless_shell() {
  if [ -n "${SEOFAST_CHROME_PATH:-}" ] && [ -x "${SEOFAST_CHROME_PATH}" ]; then
    case "$(basename "$SEOFAST_CHROME_PATH")" in
      *headless-shell*)
        echo "$SEOFAST_CHROME_PATH"
        return 0
        ;;
    esac
  fi
  for cmd in seofast-chrome-headless-shell chrome-headless-shell; do
    if need_cmd "$cmd"; then
      command -v "$cmd"
      return 0
    fi
  done
  for file in /usr/local/bin/seofast-chrome-headless-shell /usr/local/bin/chrome-headless-shell /opt/seofast-player/chrome-headless-shell/chrome-headless-shell-linux64/chrome-headless-shell; do
    if [ -x "$file" ]; then
      echo "$file"
      return 0
    fi
  done
  return 1
}

install_unzip_if_needed() {
  if need_cmd unzip; then
    return 0
  fi
  if need_cmd apt-get; then
    as_root apt-get update
    as_root apt-get install -y unzip ca-certificates
  elif need_cmd dnf; then
    as_root dnf install -y unzip ca-certificates
  elif need_cmd yum; then
    as_root yum install -y unzip ca-certificates
  elif need_cmd apk; then
    as_root apk add --no-cache unzip ca-certificates
  else
    echo "PERINGATAN: unzip belum tersedia dan package manager tidak dikenali." >&2
    return 1
  fi
}

install_chrome_headless_shell_deps() {
  if need_cmd apt-get; then
    as_root apt-get update
    as_root apt-get install -y --no-install-recommends \
      ca-certificates \
      fonts-liberation \
      libasound2t64 \
      libatk-bridge2.0-0 \
      libatk1.0-0 \
      libcairo2 \
      libcups2 \
      libdrm2 \
      libgbm1 \
      libglib2.0-0 \
      libgtk-3-0 \
      libnspr4 \
      libnss3 \
      libpango-1.0-0 \
      libx11-6 \
      libx11-xcb1 \
      libxcb1 \
      libxcomposite1 \
      libxdamage1 \
      libxext6 \
      libxfixes3 \
      libxkbcommon0 \
      libxrandr2 \
      libxshmfence1 || \
    as_root apt-get install -y --no-install-recommends \
      ca-certificates \
      fonts-liberation \
      libasound2 \
      libatk-bridge2.0-0 \
      libatk1.0-0 \
      libcairo2 \
      libcups2 \
      libdrm2 \
      libgbm1 \
      libglib2.0-0 \
      libgtk-3-0 \
      libnspr4 \
      libnss3 \
      libpango-1.0-0 \
      libx11-6 \
      libx11-xcb1 \
      libxcb1 \
      libxcomposite1 \
      libxdamage1 \
      libxext6 \
      libxfixes3 \
      libxkbcommon0 \
      libxrandr2 \
      libxshmfence1
  elif need_cmd dnf; then
    as_root dnf install -y alsa-lib atk at-spi2-atk cairo cups-libs gtk3 libX11 libXcomposite libXdamage libXext libXfixes libXrandr libdrm libxkbcommon mesa-libgbm nspr nss pango
  elif need_cmd yum; then
    as_root yum install -y alsa-lib atk at-spi2-atk cairo cups-libs gtk3 libX11 libXcomposite libXdamage libXext libXfixes libXrandr libdrm libxkbcommon mesa-libgbm nspr nss pango
  elif need_cmd apk; then
    as_root apk add --no-cache alsa-lib at-spi2-atk cairo cups-libs gtk+3.0 libx11 libxcomposite libxdamage libxext libxfixes libxrandr libxkbcommon mesa-gbm nspr nss pango
  else
    echo "PERINGATAN: package manager tidak dikenali. Dependency chrome-headless-shell mungkin perlu dipasang manual." >&2
    return 1
  fi
}

chrome_headless_shell_missing_libs() {
  binary="$1"
  if ! need_cmd ldd; then
    return 0
  fi
  ldd "$binary" 2>/dev/null | awk '/not found/ { print $1 }' | sort -u
}

chrome_headless_shell_package_for_lib() {
  lib="$1"
  case "$lib" in
    libasound.so.2) echo "libasound2t64 libasound2" ;;
    libatk-1.0.so.0) echo "libatk1.0-0" ;;
    libatk-bridge-2.0.so.0) echo "libatk-bridge2.0-0" ;;
    libatspi.so.0) echo "libatspi2.0-0" ;;
    libcairo.so.2) echo "libcairo2" ;;
    libcups.so.2) echo "libcups2" ;;
    libdrm.so.2) echo "libdrm2" ;;
    libgbm.so.1) echo "libgbm1" ;;
    libglib-2.0.so.0|libgobject-2.0.so.0|libgio-2.0.so.0|libgmodule-2.0.so.0) echo "libglib2.0-0" ;;
    libgtk-3.so.0) echo "libgtk-3-0" ;;
    libnspr4.so|libplc4.so|libplds4.so) echo "libnspr4" ;;
    libnss3.so|libnssutil3.so) echo "libnss3" ;;
    libpango-1.0.so.0) echo "libpango-1.0-0" ;;
    libX11.so.6) echo "libx11-6" ;;
    libX11-xcb.so.1|libx11-xcb.so.1) echo "libx11-xcb1" ;;
    libxcb.so.1) echo "libxcb1" ;;
    libXcomposite.so.1) echo "libxcomposite1" ;;
    libXdamage.so.1) echo "libxdamage1" ;;
    libXext.so.6) echo "libxext6" ;;
    libXfixes.so.3) echo "libxfixes3" ;;
    libXi.so.6) echo "libxi6" ;;
    libXrandr.so.2) echo "libxrandr2" ;;
    libXrender.so.1) echo "libxrender1" ;;
    libxkbcommon.so.0) echo "libxkbcommon0" ;;
    libxshmfence.so.1) echo "libxshmfence1" ;;
    *) echo "" ;;
  esac
}

install_chrome_headless_shell_missing_deps() {
  binary="$1"
  missing="$(chrome_headless_shell_missing_libs "$binary" | tr '\n' ' ')"
  if [ -z "$missing" ]; then
    return 0
  fi
  echo "Dependency chrome-headless-shell belum lengkap: ${missing}" >&2
  if ! need_cmd apt-get; then
    echo "PERINGATAN: auto-fix dependency via ldd hanya tersedia untuk apt-get saat ini." >&2
    return 1
  fi
  packages=""
  for lib in $missing; do
    mapped="$(chrome_headless_shell_package_for_lib "$lib")"
    if [ -n "$mapped" ]; then
      packages="${packages} ${mapped}"
    else
      echo "PERINGATAN: belum ada mapping paket untuk ${lib}" >&2
    fi
  done
  packages="$(printf "%s\n" $packages | awk '!seen[$0]++' | tr '\n' ' ')"
  if [ -z "$packages" ]; then
    return 1
  fi
  echo "Memasang dependency tambahan chrome-headless-shell: ${packages}" >&2
  as_root apt-get update
  # Debian 13 memakai beberapa paket t64. Jika kandidat pertama tidak ada,
  # fallback dengan nama non-t64 akan dicoba oleh daftar alternatif di atas.
  as_root apt-get install -y --no-install-recommends $packages || {
    filtered=""
    for pkg in $packages; do
      if apt-cache show "$pkg" >/dev/null 2>&1; then
        filtered="${filtered} ${pkg}"
      fi
    done
    [ -n "$filtered" ] || return 1
    as_root apt-get install -y --no-install-recommends $filtered
  }
}

verify_chrome_headless_shell_ready() {
  binary="$1"
  missing="$(chrome_headless_shell_missing_libs "$binary" | tr '\n' ' ')"
  if [ -n "$missing" ]; then
    install_chrome_headless_shell_missing_deps "$binary" || true
    missing="$(chrome_headless_shell_missing_libs "$binary" | tr '\n' ' ')"
  fi
  if [ -n "$missing" ]; then
    echo "Error: dependency chrome-headless-shell masih belum lengkap: ${missing}" >&2
    echo "Jalankan manual: ldd ${binary} | grep 'not found'" >&2
    return 1
  fi
  if ! "$binary" --version >/dev/null 2>&1; then
    echo "Error: chrome-headless-shell belum bisa dijalankan: ${binary}" >&2
    return 1
  fi
  return 0
}

chrome_headless_shell_url() {
  if [ -n "${SEOFAST_CHROME_HEADLESS_SHELL_URL:-}" ]; then
    echo "$SEOFAST_CHROME_HEADLESS_SHELL_URL"
    return 0
  fi
  if ! need_cmd python3; then
    return 1
  fi
  meta="${TMPDIR:-/tmp}/seofast-cft-versions.$$"
  download "https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json" "$meta" >/dev/null
  python3 - "$meta" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
downloads = data["channels"]["Stable"]["downloads"]["chrome-headless-shell"]
for item in downloads:
    if item.get("platform") == "linux64":
        print(item["url"])
        break
else:
    raise SystemExit(1)
PY
  rm -f "$meta"
}

install_chrome_headless_shell() {
  if find_chrome_headless_shell >/dev/null 2>&1; then
    return 0
  fi
  if [ "$(detect_arch)" != "x64" ]; then
    echo "chrome-headless-shell otomatis hanya didukung installer ini untuk linux x64." >&2
    return 1
  fi
  install_unzip_if_needed || return 1
  install_chrome_headless_shell_deps || true
  url="$(chrome_headless_shell_url)" || return 1
  echo "Mengunduh chrome-headless-shell..."
  tmp_player="${TMPDIR:-/tmp}/seofast-player-install.$$"
  zip_file="${tmp_player}/chrome-headless-shell.zip"
  mkdir -p "$tmp_player"
  download "$url" "$zip_file"
  unzip -q "$zip_file" -d "$tmp_player"
  source_bin="${tmp_player}/chrome-headless-shell-linux64/chrome-headless-shell"
  if [ ! -x "$source_bin" ]; then
    echo "chrome-headless-shell tidak ditemukan di archive." >&2
    rm -rf "$tmp_player"
    return 1
  fi
  as_root mkdir -p /opt/seofast-player/chrome-headless-shell
  as_root rm -rf /opt/seofast-player/chrome-headless-shell/chrome-headless-shell-linux64
  as_root cp -R "${tmp_player}/chrome-headless-shell-linux64" /opt/seofast-player/chrome-headless-shell/
  as_root ln -sfn /opt/seofast-player/chrome-headless-shell/chrome-headless-shell-linux64/chrome-headless-shell /usr/local/bin/seofast-chrome-headless-shell
  rm -rf "$tmp_player"
  verify_chrome_headless_shell_ready /usr/local/bin/seofast-chrome-headless-shell || return 1
  echo "chrome-headless-shell: /usr/local/bin/seofast-chrome-headless-shell"
}

find_chromium() {
  if [ -n "${SEOFAST_CHROME_PATH:-}" ] && [ -x "${SEOFAST_CHROME_PATH}" ]; then
    echo "$SEOFAST_CHROME_PATH"
    return 0
  fi
  for cmd in chromium chromium-browser google-chrome google-chrome-stable; do
    if need_cmd "$cmd"; then
      command -v "$cmd"
      return 0
    fi
  done
  for file in /usr/bin/chromium /usr/bin/chromium-browser /usr/bin/google-chrome /usr/bin/google-chrome-stable; do
    if [ -x "$file" ]; then
      echo "$file"
      return 0
    fi
  done
  return 1
}

install_chromium() {
  if find_chromium >/dev/null 2>&1; then
    return 0
  fi
  echo "Chromium belum ditemukan. Mencoba install Chromium headless/external browser..."
  if need_cmd apt-get; then
    as_root apt-get update
    if ! as_root apt-get install -y chromium; then
      as_root apt-get install -y chromium-browser
    fi
  elif need_cmd dnf; then
    as_root dnf install -y chromium
  elif need_cmd yum; then
    as_root yum install -y chromium
  elif need_cmd apk; then
    as_root apk add --no-cache chromium
  else
    echo "PERINGATAN: package manager tidak dikenali. Install Chromium manual lalu set SEOFAST_CHROME_PATH." >&2
    return 1
  fi
}

arch="$(detect_arch)"
asset="seofast-linux-${arch}"
echo "Arsitektur terdeteksi: ${arch}"
echo "Asset release: ${asset}"
if [ "$VERSION" = "latest" ]; then
  url="https://github.com/${REPO}/releases/latest/download/${asset}"
else
  url="https://github.com/${REPO}/releases/download/${VERSION}/${asset}"
fi

tmp_dir="${TMPDIR:-/tmp}/seofast-install.$$"
tmp_bin="${tmp_dir}/${BIN_NAME}"
mkdir -p "$tmp_dir"
trap 'rm -rf "$tmp_dir"' EXIT INT TERM

echo "Mengunduh ${asset}..."
download "$url" "$tmp_bin"
chmod +x "$tmp_bin"
bytes="$(wc -c < "$tmp_bin" | tr -d ' ')"
echo "Download selesai: ${bytes} bytes"

echo "Memasang ${BIN_NAME} ke ${INSTALL_DIR}/${BIN_NAME}..."
as_root mkdir -p "$INSTALL_DIR"
as_root install -m 755 "$tmp_bin" "${INSTALL_DIR}/${BIN_NAME}"
echo "Binary terpasang."
cleanup_legacy_units

echo "Verifikasi:"
"${INSTALL_DIR}/${BIN_NAME}" --help >/dev/null
echo "SeoFast terpasang: ${INSTALL_DIR}/${BIN_NAME}"

if "${INSTALL_DIR}/${BIN_NAME}" fingerprint show >/dev/null 2>&1; then
  echo "Fingerprint sudah tersedia."
else
  echo "Setup fingerprint unik untuk sistem ini..."
  "${INSTALL_DIR}/${BIN_NAME}" fingerprint init
fi

setup_player_wizard
player_file="$(seofast_config_dir)/player.json"
chrome_path="$(json_string_value "$player_file" "path")"
if [ -n "$chrome_path" ] && [ -x "$chrome_path" ]; then
  export SEOFAST_CHROME_PATH="$chrome_path"
else
  chrome_path="$(find_chrome_headless_shell 2>/dev/null || find_chromium 2>/dev/null || true)"
  if [ -n "$chrome_path" ]; then
    export SEOFAST_CHROME_PATH="$chrome_path"
  else
    echo "PERINGATAN: browser player belum tersedia. Jalankan seofast player untuk memilih/memasang browser." >&2
  fi
fi

if systemd_available; then
  if ask_yes_no "Install SeoFast Chromium sebagai service systemd?" "y"; then
    SEOFAST_CHROME_PATH="${chrome_path:-${SEOFAST_CHROME_PATH:-}}" as_root "${INSTALL_DIR}/${BIN_NAME}" service install
  else
    echo "Install service dilewati. Jalankan foreground dengan: seofast start"
  fi
else
  echo "Systemd tidak terdeteksi, service dilewati. Jalankan foreground dengan: seofast start"
fi

if ask_yes_no "Setup Telegram group/topic untuk notifikasi login, earnings harian, dan log?" "n"; then
  echo "WARNING: Pastikan BOT telegram valid dan sudah ditambahkan ke dalam group"
  "${INSTALL_DIR}/${BIN_NAME}" telegram setup
else
  echo "Kamu bisa setup nanti menggunakan perintah: seofast telegram setup"
fi

setup_credentials_wizard
setup_gmail_wizard
setup_devtools_wizard
print_setup_summary

echo
echo "Silahkan jalankan 'seofast login' dan 'seofast start' untuk memulai tugas"
echo "Selesai."
