#!/bin/bash
# User data QA: Java 21 + SSM (el agente ya viene en AL2023). Sin Docker, sin Postgres.
set -euxo pipefail
dnf update -y
dnf install -y java-21-amazon-corretto-headless
install -d -m 0755 /opt/edugest
cat >/etc/profile.d/edugest.sh <<'EOF'
export SPRING_PROFILES_ACTIVE=cloud-dev
export JAVA_TOOL_OPTIONS="-Xms128m -Xmx384m"
EOF
# El JAR se copia despues por SSM (aws ssm send-command o Session Manager).
# systemd unit se crea en el primer deploy de la app, no aqui.
