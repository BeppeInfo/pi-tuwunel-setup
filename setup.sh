#!/usr/bin/env bash
# Instala Tuwunel em Debian/Raspberry Pi OS.
# NETWORK_MODE=clearnet: Caddy HTTPS → 6167 (não grava o cartão, não configura roteador/DNS).
# NETWORK_MODE=tor: onion v3 como server_name; Caddy tls internal em 127.0.0.1:443.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/config.env}"
HS_DIR=/var/lib/tor/tuwunel
HS_HOSTNAME_FILE="$HS_DIR/hostname"

if [[ ${EUID} -ne 0 ]]; then
  echo "Execute como root: sudo $0" >&2
  exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Falta $CONFIG_FILE — copie config.env.example para config.env" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

: "${NETWORK_MODE:=clearnet}"
: "${LISTEN_ADDR:=127.0.0.1}"
: "${LISTEN_PORT:=6167}"
: "${DATABASE_PATH:=/var/lib/tuwunel}"
: "${ALLOW_REGISTRATION:=true}"
: "${ALLOW_FEDERATION:=true}"
: "${MAX_REQUEST_SIZE:=20000000}"
: "${INSTALL_UFW:=0}"
: "${INSTALL_UNATTENDED_UPGRADES:=1}"
: "${EXTERNAL_HTTP_PORT:=80}"
: "${EXTERNAL_HTTPS_PORT:=443}"
: "${TLS_MODE:=acme}"
: "${SERVER_NAME:=}"
: "${MATRIX_HOST:=}"
: "${ROOT_MESSAGE:=}"
PROXY_BLOCK=""
TOR_GLOBAL_BLOCK=""

# Texto em "/" no navegador (o do Tuwunel é fixo no código). Vazio = padrão.
ROOT_LINE=""
if [[ -n "$ROOT_MESSAGE" ]]; then
  if [[ "$ROOT_MESSAGE" == *'`'* ]]; then
    echo "ROOT_MESSAGE não pode conter crase (\`)" >&2
    exit 1
  fi
  ROOT_LINE="respond / \`${ROOT_MESSAGE}\` 200"
fi

if [[ -z "${REGISTRATION_TOKEN:-}" ]]; then
  REGISTRATION_TOKEN="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
  echo "REGISTRATION_TOKEN gerado (guarde): $REGISTRATION_TOKEN"
fi

wait_for_onion() {
  local i
  echo "==> Aguardando endereço onion em $HS_HOSTNAME_FILE"
  for i in $(seq 1 60); do
    if [[ -s "$HS_HOSTNAME_FILE" ]]; then
      SERVER_NAME="$(tr -d '[:space:]' <"$HS_HOSTNAME_FILE")"
      return 0
    fi
    sleep 1
  done
  echo "Tor não criou $HS_HOSTNAME_FILE a tempo. journalctl -u tor -e" >&2
  exit 1
}

ensure_tor_include() {
  install -d -m 755 /etc/tor/torrc.d
  if ! grep -qE '^[[:space:]]*%include /etc/tor/torrc.d/' /etc/tor/torrc 2>/dev/null; then
    printf '\n%%include /etc/tor/torrc.d/*.conf\n' >>/etc/tor/torrc
  fi
}

existing_server_name() {
  local f=/etc/tuwunel/tuwunel.toml
  [[ -f "$f" ]] || return 0
  awk -F'"' '/^[[:space:]]*server_name[[:space:]]*=/{print $2; exit}' "$f"
}

setup_tor() {
  echo "==> Tor (hidden service + SOCKS localhost)"
  apt-get install -y tor
  ensure_tor_include
  export LISTEN_PORT
  render "$SCRIPT_DIR/torrc.template" /etc/tor/torrc.d/tuwunel.conf
  chmod 644 /etc/tor/torrc.d/tuwunel.conf
  install -d -m 700 -o debian-tor -g debian-tor "$HS_DIR"
  systemctl enable --now tor
  systemctl reload tor 2>/dev/null || systemctl restart tor
  wait_for_onion
  MATRIX_HOST="$SERVER_NAME"
  # Clientes em HTTP: Tor já cifra, e o Tor Browser recusa o cert tls internal.
  # Só a federação (WELL_KNOWN_SERVER) precisa de HTTPS.
  WELL_KNOWN_CLIENT="http://${SERVER_NAME}"
  WELL_KNOWN_SERVER="${SERVER_NAME}:443"
  CLIENT_URL="http://${SERVER_NAME}"
  PROXY_BLOCK="$(cat "$SCRIPT_DIR/tuwunel-proxy-tor.snippet")"
  TOR_GLOBAL_BLOCK="$(cat "$SCRIPT_DIR/tuwunel-global-tor.snippet")"
}

setup_clearnet_urls() {
  : "${SERVER_NAME:?defina SERVER_NAME em config.env}"
  : "${MATRIX_HOST:?defina MATRIX_HOST em config.env}"
  case "$TLS_MODE" in
    acme) TLS_LINE="" ;;
    internal) TLS_LINE="tls internal" ;;
    *)
      echo "TLS_MODE deve ser acme ou internal" >&2
      exit 1
      ;;
  esac
  if [[ "$TLS_MODE" == "acme" && "$EXTERNAL_HTTP_PORT" != "80" ]]; then
    echo "Aviso: Let's Encrypt HTTP-01 só valida na porta 80. Com EXTERNAL_HTTP_PORT=${EXTERNAL_HTTP_PORT} o certificado automático tende a falhar. Use TLS_MODE=internal ou DNS-01 no Caddy." >&2
  fi
  if [[ "$EXTERNAL_HTTPS_PORT" == "443" ]]; then
    WELL_KNOWN_CLIENT="https://${MATRIX_HOST}"
    CLIENT_URL="https://${MATRIX_HOST}"
  else
    WELL_KNOWN_CLIENT="https://${MATRIX_HOST}:${EXTERNAL_HTTPS_PORT}"
    CLIENT_URL="https://${MATRIX_HOST}:${EXTERNAL_HTTPS_PORT}"
  fi
  WELL_KNOWN_SERVER="${MATRIX_HOST}:${EXTERNAL_HTTPS_PORT}"
}

install_caddy_pkg() {
  apt-get update
  apt-get install -y caddy
}

setup_caddy() {
  echo "==> Caddy (HTTPS :${EXTERNAL_HTTPS_PORT} → Tuwunel ${LISTEN_ADDR}:${LISTEN_PORT})"
  install_caddy_pkg
  render "$SCRIPT_DIR/Caddyfile.template" /etc/caddy/Caddyfile
  caddy validate --config /etc/caddy/Caddyfile
  systemctl enable --now caddy
  systemctl reload caddy
}

setup_caddy_tor() {
  echo "==> Caddy Tor (127.0.0.1:80/443 tls internal → ${LISTEN_ADDR}:${LISTEN_PORT})"
  install_caddy_pkg
  render "$SCRIPT_DIR/Caddyfile.tor.template" /etc/caddy/Caddyfile
  caddy validate --config /etc/caddy/Caddyfile
  systemctl enable --now caddy
  systemctl reload caddy
}

render() {
  local src="$1" dest="$2"
  envsubst <"$src" >"$dest"
}

case "$NETWORK_MODE" in
  clearnet)
    setup_clearnet_urls
    ;;
  tor)
    TLS_LINE=""
    ;;
  *)
    echo "NETWORK_MODE deve ser clearnet ou tor" >&2
    exit 1
    ;;
esac

echo "==> Sistema atualizado"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade

echo "==> Pacotes base"
apt-get install -y ca-certificates curl gpg apt-transport-https gettext-base

if [[ "$INSTALL_UNATTENDED_UPGRADES" == "1" ]]; then
  apt-get install -y unattended-upgrades
fi

if [[ "$NETWORK_MODE" == "tor" ]]; then
  setup_tor
fi

PREV_NAME="$(existing_server_name || true)"
if [[ -n "$PREV_NAME" && "$PREV_NAME" != "$SERVER_NAME" ]]; then
  echo "server_name já é '$PREV_NAME' em /etc/tuwunel/tuwunel.toml; recusar mudar para '$SERVER_NAME' (wipe da DB). Abortando." >&2
  exit 1
fi

echo "==> Repositório Tuwunel"
install -d /usr/share/keyrings
curl -fsSL -o /usr/share/keyrings/tuwunel-archive-keyring.gpg \
  https://apt.f.dog/tuwunel-archive-keyring.gpg
cat >/etc/apt/sources.list.d/tuwunel.sources <<EOF
Types: deb
URIs: https://apt.f.dog
Suites: stable
Components: main
Signed-By: /usr/share/keyrings/tuwunel-archive-keyring.gpg
EOF
apt-get update
apt-get install -y tuwunel

export SERVER_NAME MATRIX_HOST LISTEN_ADDR LISTEN_PORT DATABASE_PATH
export ALLOW_REGISTRATION ALLOW_FEDERATION REGISTRATION_TOKEN MAX_REQUEST_SIZE
export WELL_KNOWN_CLIENT WELL_KNOWN_SERVER
export EXTERNAL_HTTP_PORT EXTERNAL_HTTPS_PORT TLS_LINE PROXY_BLOCK TOR_GLOBAL_BLOCK ROOT_LINE

echo "==> /etc/tuwunel/tuwunel.toml"
install -d -m 755 /etc/tuwunel
render "$SCRIPT_DIR/tuwunel.toml.template" /etc/tuwunel/tuwunel.toml
chown -R root:root /etc/tuwunel
chmod 644 /etc/tuwunel/tuwunel.toml

install -d -m 700 -o tuwunel -g tuwunel "$DATABASE_PATH"
if [[ "$DATABASE_PATH" != /var/lib/tuwunel ]]; then
  install -d /etc/systemd/system/tuwunel.service.d
  cat >/etc/systemd/system/tuwunel.service.d/override.conf <<EOF
[Service]
ReadWritePaths=$DATABASE_PATH
EOF
fi

systemctl daemon-reload
systemctl enable tuwunel.service
# restart, não --now: em reexecução o processo antigo seguiria com o toml velho
systemctl restart tuwunel.service

if [[ "$NETWORK_MODE" == "clearnet" ]]; then
  setup_caddy
elif [[ "$NETWORK_MODE" == "tor" ]]; then
  setup_caddy_tor
fi

if [[ "$INSTALL_UFW" == "1" ]]; then
  echo "==> ufw"
  apt-get install -y ufw
  ufw allow OpenSSH
  if [[ "$NETWORK_MODE" == "clearnet" ]]; then
    ufw allow "${EXTERNAL_HTTP_PORT}/tcp"
    ufw allow "${EXTERNAL_HTTPS_PORT}/tcp"
  fi
  ufw --force enable
fi

echo
echo "Pronto."
echo "  Modo:     ${NETWORK_MODE}"
echo "  Tuwunel:  $(systemctl is-active tuwunel.service)"
if [[ "$NETWORK_MODE" == "clearnet" ]]; then
  echo "  Caddy:    $(systemctl is-active caddy)"
else
  echo "  Tor:      $(systemctl is-active tor)"
  echo "  Caddy:    $(systemctl is-active caddy)"
fi
echo "  MXID:     @usuario:${SERVER_NAME}"
echo "  Cliente:  ${CLIENT_URL}"
echo "  Federação well-known: ${WELL_KNOWN_SERVER}"
echo "  Token:    ${REGISTRATION_TOKEN}"
echo
if [[ "$NETWORK_MODE" == "tor" ]]; then
  echo "Tor-only: sem DNS; Caddy só em 127.0.0.1 (tls internal). Guarde ${HS_DIR}."
  echo "Clientes: Tor Browser / Orbot, URL ${CLIENT_URL} (HTTP) ou https:// (certificado local)."
  echo "Federação HTTPS no onion; o outro homeserver precisa aceitar o cert interno, e.g."
  echo "  allow_invalid_tls_certificates = true"
  echo "Não federação com matrix.org — só quem fala Tor + TLS frouxo."
  echo "Checagem HTTP:  curl -sS --socks5-hostname 127.0.0.1:9050 ${CLIENT_URL}/_matrix/client/versions"
  echo "Checagem HTTPS: curl -sk --socks5-hostname 127.0.0.1:9050 https://${SERVER_NAME}/_matrix/federation/v1/version"
else
  echo "Ainda no roteador: IP LAN estático; encaminhar ${EXTERNAL_HTTP_PORT} e ${EXTERNAL_HTTPS_PORT} para o Pi."
  echo "Ainda no DNS: A/AAAA do apex (e de ${MATRIX_HOST} se não for CNAME) para o IP público do gateway."
  if [[ "$EXTERNAL_HTTPS_PORT" != "443" ]]; then
    echo "Porta HTTPS ≠ 443: publique SRV _matrix-fed._tcp.${SERVER_NAME} → ${MATRIX_HOST} ${EXTERNAL_HTTPS_PORT}"
    echo "e no Element use a URL completa ${CLIENT_URL} se o well-known na 443 do apex não existir."
  fi
  echo "Checagem:  curl -sS ${CLIENT_URL}/_matrix/client/versions"
fi
echo "Logs:      journalctl -u tuwunel -e"
