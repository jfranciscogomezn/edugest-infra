#!/bin/bash
# Bootstrap QA en la EC2 ya existente. No recrea la instancia.
set -euxo pipefail

BUCKET="${1:?bucket}"
API_HOSTNAME="${2:?api hostname}"

install -d -m 0755 /opt/edugest /etc/edugest

if ! command -v java >/dev/null 2>&1; then
  dnf install -y java-21-amazon-corretto-headless
fi

if ! command -v caddy >/dev/null 2>&1; then
  curl -fsSL -o /tmp/caddy.tgz "https://github.com/caddyserver/caddy/releases/download/v2.9.1/caddy_2.9.1_linux_amd64.tar.gz"
  tar -xzf /tmp/caddy.tgz -C /tmp caddy
  install -m 0755 /tmp/caddy /usr/local/bin/caddy
fi

aws s3 cp "s3://${BUCKET}/bootstrap/ms-security.service" /etc/systemd/system/ms-security.service
aws s3 cp "s3://${BUCKET}/bootstrap/caddy.service" /etc/systemd/system/caddy.service
aws s3 cp "s3://${BUCKET}/bootstrap/Caddyfile" /etc/caddy/Caddyfile
aws s3 cp "s3://${BUCKET}/bootstrap/ms-security.env" /etc/edugest/ms-security.env
aws s3 cp "s3://${BUCKET}/bootstrap/caddy.env" /etc/edugest/caddy.env
chmod 0600 /etc/edugest/ms-security.env /etc/edugest/caddy.env
install -d -m 0755 /etc/caddy /var/lib/caddy
id caddy >/dev/null 2>&1 || useradd --system --home /var/lib/caddy --shell /usr/sbin/nologin caddy
chown -R caddy:caddy /var/lib/caddy

printf 'API_HOSTNAME=%s\n' "$API_HOSTNAME" >/etc/edugest/caddy.env

systemctl daemon-reload
systemctl enable caddy
systemctl restart caddy
systemctl enable ms-security
if [ -f /opt/edugest/ms-security.jar ]; then
  systemctl restart ms-security
else
  echo "JAR aun no esta; el workflow de GitHub lo copia y arranca el servicio."
fi
