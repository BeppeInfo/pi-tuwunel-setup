# Instalação Tuwunel (Debian / Raspberry Pi OS)

Automatiza o que o guia `rpi4-pios-tuwunel.md` faz **depois** do sistema no ar. Não grava o SD.

Dois modos (`NETWORK_MODE` em `config.env`):

| | `clearnet` (padrão) | `tor` |
|---|---|---|
| Identidade | `SERVER_NAME` DNS (`@user:exemplo.com`) | onion v3 gerado (`@user:….onion`) |
| Exposição | Caddy + TLS, portas 80/443 | Tor HS 80/443 → Caddy só em 127.0.0.1 (`tls internal`) |
| Você precisa | DNS + encaminhamento no roteador | nada disso |
| Federação matrix.org | sim | **não** (só outros `.onion`) |

## Uso

```bash
$ cd pi-tuwunel-setup
$ cp config.env.example config.env
$ nano config.env
$ sudo ./setup.sh
```

Exige `apt` (Debian, Raspberry Pi OS Lite 64-bit, Ubuntu). Arquitetura `amd64` ou `arm64`.

### Tor-only

```bash
NETWORK_MODE=tor
SERVER_NAME=
MATRIX_HOST=
```

O script instala `tor`, cria `/var/lib/tor/tuwunel`, espera o hostname, e usa esse `.onion` como `server_name`. Caddy escuta **só 127.0.0.1** com `tls internal` (federação Matrix exige HTTPS). SOCKS só em `127.0.0.1:9050`; Tuwunel manda **toda** a saída por `socks5h`.

O outro homeserver (ex. choppa.xyz) precisa aceitar o certificado interno:

```toml
allow_invalid_tls_certificates = true
```

Clientes podem continuar em `http://<onion>/`. Federação usa `https://<onion>/`.

**Não apague** `/var/lib/tor/tuwunel` — é a identidade. Reexecutar o script reutiliza o mesmo onion. Mudar `server_name` depois exige wipe da DB; o script recusa se o toml antigo for outro nome.

Clientes: Tor Browser / Orbot, URL `http://<onion>/` (HTTP; TLS no onion não entra).

```bash
curl -sS --socks5-hostname 127.0.0.1:9050 http://<onion>/_matrix/client/versions
curl -sk --socks5-hostname 127.0.0.1:9050 https://<onion>/_matrix/federation/v1/version
```

## Arquivos

| Arquivo | Função |
|---|---|
| `config.env.example` | Variáveis (modo, domínio, token, ufw, `ROOT_MESSAGE`) |
| `config.env` | Sua cópia — não versionar |
| `tuwunel.toml.template` | Vira `/etc/tuwunel/tuwunel.toml` |
| `tuwunel-proxy-tor.snippet` | Bloco `[global.proxy]` no modo tor |
| `tuwunel-global-tor.snippet` | Modo tor: aceita cert interno dos outros onions, timeouts maiores |
| `Caddyfile.template` | Clearnet: `/etc/caddy/Caddyfile` |
| `Caddyfile.tor.template` | Tor: Caddy em 127.0.0.1 com `tls internal` |
| `torrc.template` | Só tor: `/etc/tor/torrc.d/tuwunel.conf` |
| `setup.sh` | Repositórios, Tuwunel, Caddy ou Tor, systemd |

`REGISTRATION_TOKEN` vazio faz o script gerar um e imprimir no fim.

## Usuário admin com registro fechado

O primeiro usuário criado no servidor vira admin. Com `ALLOW_REGISTRATION=false`:

**DB vazia:** no primeiro start o Tuwunel loga um token de uso único que funciona mesmo com registro fechado. Registre pelo cliente com ele.

```bash
journalctl -u tuwunel -e | grep -i token
```

**Já existem usuários:** pela CLI. A DB só aceita um processo, então pare o serviço antes:

```bash
sudo systemctl stop tuwunel
sudo -u tuwunel tuwunel -c /etc/tuwunel/tuwunel.toml \
  --execute "users create-user alice" \
  --execute "users make-user-admin @alice:SERVER_NAME"
# senha aleatória sai na saída se omitida; confira, Ctrl+C
sudo systemctl start tuwunel
```

No modo tor, `SERVER_NAME` é o `.onion`. Nomes de comando mudam entre versões (`create_user` / `create-user`): `--execute "users --help"` lista os atuais.

**Já tem um admin:** na sala `#admins:SERVER_NAME`:

```
!admin users create-user bob
!admin users make-user-admin @bob:SERVER_NAME
```

Alternativa: `ALLOW_REGISTRATION=true` com `REGISTRATION_TOKEN` já só deixa registrar quem tem o token.

## Portas externas ≠ 80/443 (só clearnet)

No `config.env`:

```bash
EXTERNAL_HTTP_PORT=8080
EXTERNAL_HTTPS_PORT=8443
TLS_MODE=internal
```

O Caddy passa a escutar essas portas; o well-known do Tuwunel vira `https://talk.exemplo.com:8443` e `talk.exemplo.com:8443`.

Let's Encrypt **HTTP-01 só na porta 80**. Sem 80: `TLS_MODE=internal` (certificado local) ou DNS-01 à mão no Caddy. Encaminhe no roteador as mesmas portas. Federação sem 443 no apex: SRV `_matrix-fed._tcp.SERVER_NAME` para `MATRIX_HOST` na `EXTERNAL_HTTPS_PORT`. No Element, URL completa se o cliente não achar well-known na 443.

## Continua manual

**Clearnet:** Raspberry Pi Imager + SSH; IP LAN estático e encaminhamento; DNS (seção 3 do guia); disco USB / bind-mount de `/var/lib/tuwunel`.

**Tor:** Imager + SSH; backup de `/var/lib/tor/tuwunel` e `/var/lib/tuwunel`. Sem roteador e sem DNS.
