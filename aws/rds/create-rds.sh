#!/usr/bin/env bash
# =============================================================================
# EduGest -- Crear instancia RDS PostgreSQL 16 (Free Tier) en AWS
# Script Bash (Linux / macOS / WSL)
#
# Uso:
#   chmod +x create-rds.sh
#   ./create-rds.sh
#   ./create-rds.sh --region us-east-1 --password "MiPassword123!"
#
# Convencion de BD: db_<servicio>  →  db_security
# =============================================================================
set -euo pipefail

REGION="${REGION:-us-east-1}"
DB_INSTANCE_ID="${DB_INSTANCE_ID:-edugest-dev}"
DB_NAME="${DB_NAME:-db_security}"
MASTER_USERNAME="${MASTER_USERNAME:-postgres}"
DB_PASSWORD="${DB_PASSWORD:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --region)   REGION="$2"; shift 2 ;;
        --password) DB_PASSWORD="$2"; shift 2 ;;
        --id)       DB_INSTANCE_ID="$2"; shift 2 ;;
        *) echo "Argumento desconocido: $1"; exit 1 ;;
    esac
done

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}$1${NC}"; }
warn() { echo -e "  ${YELLOW}$1${NC}"; }
err()  { echo -e "  ${RED}$1${NC}"; exit 1; }

command -v aws >/dev/null || err "AWS CLI no encontrado"
aws sts get-caller-identity --region "$REGION" >/dev/null 2>&1 || err "Credenciales AWS invalidas. Ejecuta: aws configure"

if [[ -z "$DB_PASSWORD" ]]; then
    read -rs -p "Contrasena master de RDS (8-128 chars, sin / \" @): " DB_PASSWORD
    echo
fi
[[ ${#DB_PASSWORD} -lt 8 ]] && err "La contrasena debe tener al menos 8 caracteres"
[[ "$DB_PASSWORD" =~ [/\"] ]] && err "La contrasena no puede contener / \" @"
[[ "$DB_PASSWORD" == *@* ]] && err "La contrasena no puede contener @"

echo -e "${CYAN}=== EduGest: Creando instancia RDS PostgreSQL 16 ===${NC}"
echo "Region: $REGION | Instancia: $DB_INSTANCE_ID | DB: $DB_NAME"

# --- 0. Ya existe? ------------------------------------------------------------
echo -e "\n${YELLOW}[0/6] Verificando si la instancia ya existe...${NC}"
EXISTING=$(aws rds describe-db-instances \
    --db-instance-identifier "$DB_INSTANCE_ID" \
    --query "DBInstances[0].DBInstanceStatus" \
    --output text \
    --region "$REGION" 2>/dev/null || true)

if [[ -n "$EXISTING" && "$EXISTING" != "None" ]]; then
    warn "Instancia ya existe (estado: $EXISTING)"
    [[ "$EXISTING" != "available" ]] && aws rds wait db-instance-available \
        --db-instance-identifier "$DB_INSTANCE_ID" --region "$REGION"
    ENDPOINT=$(aws rds describe-db-instances \
        --db-instance-identifier "$DB_INSTANCE_ID" \
        --query "DBInstances[0].Endpoint.Address" \
        --output text --region "$REGION")
    echo -e "${GREEN}Endpoint: $ENDPOINT${NC}"
    echo "Siguiente paso: ./init-rds-db.sh --endpoint \"$ENDPOINT\" --master-password \"<password>\""
    exit 0
fi
ok "No existe. Continuando..."

# --- 1. VPC -------------------------------------------------------------------
echo -e "\n${YELLOW}[1/6] Obteniendo VPC por defecto...${NC}"
VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" --output text --region "$REGION")
[[ "$VPC_ID" == "None" || -z "$VPC_ID" ]] && err "No hay VPC por defecto en $REGION"
ok "VPC: $VPC_ID"

# --- 2. Subnets ---------------------------------------------------------------
echo -e "\n${YELLOW}[2/6] Obteniendo subnets...${NC}"
mapfile -t SUBNET_ARR < <(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=defaultForAz,Values=true" \
    --query "Subnets[*].SubnetId" --output text --region "$REGION" | tr '\t' '\n' | grep '^subnet-')
[[ ${#SUBNET_ARR[@]} -lt 2 ]] && err "Se necesitan minimo 2 subnets. Encontradas: ${#SUBNET_ARR[@]}"
SUBNET_ARR=("${SUBNET_ARR[@]:0:3}")
ok "Subnets (${#SUBNET_ARR[@]}): ${SUBNET_ARR[*]}"

# --- 3. Subnet group ----------------------------------------------------------
echo -e "\n${YELLOW}[3/6] Creando DB Subnet Group...${NC}"
SUBNET_GROUP_NAME="${DB_INSTANCE_ID}-subnet-group"
if ! aws rds create-db-subnet-group \
    --db-subnet-group-name "$SUBNET_GROUP_NAME" \
    --db-subnet-group-description "Subnet group para EduGest dev" \
    --subnet-ids "${SUBNET_ARR[@]}" \
    --region "$REGION" --output text >/dev/null 2>&1; then
    warn "Subnet group ya existe: $SUBNET_GROUP_NAME"
else
    ok "Subnet group creado: $SUBNET_GROUP_NAME"
fi

# --- 4. Security Group --------------------------------------------------------
echo -e "\n${YELLOW}[4/6] Creando Security Group...${NC}"
SG_NAME="${DB_INSTANCE_ID}-sg"
SG_ID=$(aws ec2 create-security-group \
    --group-name "$SG_NAME" \
    --description "EduGest RDS dev - PostgreSQL 5432" \
    --vpc-id "$VPC_ID" \
    --query "GroupId" --output text --region "$REGION" 2>/dev/null || true)

if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
    SG_ID=$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
        --query "SecurityGroups[0].GroupId" --output text --region "$REGION")
    warn "Security group ya existe: $SG_ID"
else
    aws ec2 authorize-security-group-ingress \
        --group-id "$SG_ID" --protocol tcp --port 5432 --cidr "0.0.0.0/0" \
        --region "$REGION" >/dev/null
    ok "Security group creado: $SG_ID"
    warn "Puerto 5432 abierto a 0.0.0.0/0 (solo desarrollo)"
fi

# --- 5. Version + create ------------------------------------------------------
echo -e "\n${YELLOW}[5/6] Consultando versiones PostgreSQL 16...${NC}"
ENGINE_VERSION=$(aws rds describe-db-engine-versions \
    --engine postgres \
    --query "DBEngineVersions[?starts_with(EngineVersion,'16.')].EngineVersion" \
    --output text --region "$REGION" | tr '\t' '\n' | grep '^16\.' | sort -V | tail -1)
[[ -z "$ENGINE_VERSION" ]] && err "No hay versiones PostgreSQL 16 en $REGION"
ok "Version seleccionada: $ENGINE_VERSION"

echo -e "\n${YELLOW}[5/6] Creando instancia RDS (~5-10 min)...${NC}"
if ! aws rds create-db-instance \
    --db-instance-identifier "$DB_INSTANCE_ID" \
    --db-instance-class db.t3.micro \
    --engine postgres \
    --engine-version "$ENGINE_VERSION" \
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
    --auto-minor-version-upgrade \
    --tags "Key=Project,Value=EduGest" "Key=Environment,Value=dev" \
    --region "$REGION" \
    --output text; then
    err "Error creando la instancia RDS. Revisa el mensaje de AWS arriba."
fi

echo -e "${YELLOW}Esperando estado available (~8 min)...${NC}"
aws rds wait db-instance-available \
    --db-instance-identifier "$DB_INSTANCE_ID" \
    --region "$REGION"

# --- 6. Endpoint --------------------------------------------------------------
ENDPOINT=$(aws rds describe-db-instances \
    --db-instance-identifier "$DB_INSTANCE_ID" \
    --query "DBInstances[0].Endpoint.Address" \
    --output text --region "$REGION")

echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${GREEN} INSTANCIA RDS LISTA${NC}"
echo -e "${CYAN}============================================================${NC}"
echo " Endpoint : $ENDPOINT"
echo " Puerto   : 5432"
echo " Usuario  : $MASTER_USERNAME"
echo " Engine   : PostgreSQL $ENGINE_VERSION"
echo -e "${CYAN}============================================================${NC}"
echo ""
echo -e "${YELLOW}SIGUIENTE PASO:${NC}"
echo "  ./init-rds-db.sh --endpoint \"$ENDPOINT\" --master-password \"<password>\""
