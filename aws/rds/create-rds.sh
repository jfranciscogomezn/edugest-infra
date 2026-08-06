#!/usr/bin/env bash
# =============================================================================
# EduGest — Crear instancia RDS PostgreSQL 16 (Free Tier) en AWS
# Script Bash (Linux / macOS / WSL)
#
# Uso:
#   chmod +x create-rds.sh
#   ./create-rds.sh
#   ./create-rds.sh --region us-west-2 --password "MiPassword123!"
# =============================================================================
set -euo pipefail

REGION="${REGION:-us-east-1}"
DB_INSTANCE_ID="${DB_INSTANCE_ID:-edugest-dev}"
DB_NAME="${DB_NAME:-security}"
MASTER_USERNAME="${MASTER_USERNAME:-postgres}"
DB_PASSWORD="${DB_PASSWORD:-}"
APP_USERNAME="${APP_USERNAME:-security_user}"
APP_PASSWORD="${APP_PASSWORD:-changeme_dev}"

# ─── Colores ─────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${CYAN}$1${NC}"; }
ok()   { echo -e "  ${GREEN}✓ $1${NC}"; }
warn() { echo -e "  ${YELLOW}⚠ $1${NC}"; }
err()  { echo -e "  ${RED}✗ $1${NC}"; exit 1; }

# ─── Pedir contraseña si no se pasó ──────────────────────────────────────────
if [[ -z "$DB_PASSWORD" ]]; then
    read -rs -p "Contraseña para el usuario master de RDS (mín. 8 chars): " DB_PASSWORD
    echo
fi

log "\n=== EduGest: Creando instancia RDS PostgreSQL 16 ==="
echo "Region: $REGION | Instancia: $DB_INSTANCE_ID | DB: $DB_NAME"

# ─── 1. VPC por defecto ───────────────────────────────────────────────────────
log "\n[1/6] Obteniendo VPC por defecto..."
VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" \
    --output text \
    --region "$REGION")
[[ "$VPC_ID" == "None" || -z "$VPC_ID" ]] && err "No hay VPC por defecto en $REGION"
ok "VPC: $VPC_ID"

# ─── 2. Subnets ───────────────────────────────────────────────────────────────
log "\n[2/6] Obteniendo subnets..."
SUBNET_IDS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=defaultForAz,Values=true" \
    --query "Subnets[*].SubnetId" \
    --output text \
    --region "$REGION")
SUBNET_COUNT=$(echo "$SUBNET_IDS" | wc -w)
[[ $SUBNET_COUNT -lt 2 ]] && err "Se necesitan mínimo 2 subnets. Encontradas: $SUBNET_COUNT"
ok "Subnets: $SUBNET_IDS"

# ─── 3. DB Subnet Group ──────────────────────────────────────────────────────
log "\n[3/6] Creando DB Subnet Group..."
SUBNET_GROUP_NAME="${DB_INSTANCE_ID}-subnet-group"
aws rds create-db-subnet-group \
    --db-subnet-group-name "$SUBNET_GROUP_NAME" \
    --db-subnet-group-description "Subnet group para EduGest dev" \
    --subnet-ids $SUBNET_IDS \
    --region "$REGION" \
    --output text 2>&1 || warn "Subnet group ya existe (normal en re-ejecuciones)"
ok "Subnet group: $SUBNET_GROUP_NAME"

# ─── 4. Security Group ───────────────────────────────────────────────────────
log "\n[4/6] Creando Security Group..."
SG_ID=$(aws ec2 create-security-group \
    --group-name "${DB_INSTANCE_ID}-sg" \
    --description "EduGest RDS dev - PostgreSQL 5432" \
    --vpc-id "$VPC_ID" \
    --query "GroupId" \
    --output text \
    --region "$REGION" 2>&1) || true

if [[ "$SG_ID" == *"InvalidGroup.Duplicate"* ]]; then
    SG_ID=$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=${DB_INSTANCE_ID}-sg" \
        --query "SecurityGroups[0].GroupId" \
        --output text \
        --region "$REGION")
    warn "Security group ya existe: $SG_ID"
else
    aws ec2 authorize-security-group-ingress \
        --group-id "$SG_ID" \
        --protocol tcp --port 5432 --cidr "0.0.0.0/0" \
        --region "$REGION" > /dev/null
    ok "Security group creado: $SG_ID"
    warn "Puerto 5432 abierto a 0.0.0.0/0 — SOLO PARA DESARROLLO"
fi

# ─── 5. Crear instancia RDS ──────────────────────────────────────────────────
log "\n[5/6] Creando instancia RDS (puede tardar ~8 minutos)..."
aws rds create-db-instance \
    --db-instance-identifier "$DB_INSTANCE_ID" \
    --db-instance-class db.t3.micro \
    --engine postgres \
    --engine-version "16.8" \
    --master-username "$MASTER_USERNAME" \
    --master-user-password "$DB_PASSWORD" \
    --db-name "$DB_NAME" \
    --allocated-storage 20 \
    --storage-type gp2 \
    --no-multi-az \
    --publicly-accessible \
    --db-subnet-group-name "$SUBNET_GROUP_NAME" \
    --vpc-security-group-ids "$SG_ID" \
    --backup-retention-period 7 \
    --no-deletion-protection \
    --tags "Key=Project,Value=EduGest" "Key=Environment,Value=dev" \
    --region "$REGION" \
    --output table

log "\n[5/6] Esperando disponibilidad (~8 min)..."
aws rds wait db-instance-available \
    --db-instance-identifier "$DB_INSTANCE_ID" \
    --region "$REGION"

# ─── 6. Endpoint ─────────────────────────────────────────────────────────────
ENDPOINT=$(aws rds describe-db-instances \
    --db-instance-identifier "$DB_INSTANCE_ID" \
    --query "DBInstances[0].Endpoint.Address" \
    --output text \
    --region "$REGION")

echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${GREEN} INSTANCIA RDS LISTA${NC}"
echo -e "${CYAN}============================================================${NC}"
echo " Endpoint : $ENDPOINT"
echo " Puerto   : 5432"
echo " DB Name  : $DB_NAME"
echo " Usuario  : $MASTER_USERNAME"
echo -e "${CYAN}============================================================${NC}"
echo ""
echo -e "${YELLOW}SIGUIENTE PASO — Inicializar la DB:${NC}"
echo "  ./init-rds-db.sh --endpoint \"$ENDPOINT\" --master-password \"<password>\""
echo ""
echo -e "${YELLOW}CADENA DE CONEXION (perfil cloud-dev):${NC}"
echo "  DB_HOST=$ENDPOINT"
echo "  SPRING_PROFILES_ACTIVE=cloud-dev"
