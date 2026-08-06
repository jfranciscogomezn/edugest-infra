# RDS PostgreSQL — Entorno cloud-dev

Scripts para crear y gestionar la instancia **AWS RDS PostgreSQL** usada como
base de datos compartida del equipo de desarrollo.

> Se usa exclusivamente para el entorno `cloud-dev`. Producción y staging
> tendrán su propia infraestructura gestionada por Terraform.

---

## Prerrequisitos

- AWS CLI configurado (`aws configure`) con un perfil con permisos sobre RDS, VPC y EC2
- Para `init-rds-db.*`: `psql` instalado localmente o acceso via cliente SQL

---

## Scripts

### `create-rds.ps1` / `create-rds.sh`

Crea una instancia RDS PostgreSQL 16 en la VPC por defecto de tu cuenta AWS.

**Parámetros:**

| Parámetro         | Default            | Descripción                            |
|-------------------|--------------------|----------------------------------------|
| `-Region`         | `us-east-1`        | Región AWS                             |
| `-DbPassword`     | `changeme_dev`     | Contraseña del usuario `postgres`      |
| `-InstanceClass`  | `db.t3.micro`      | Clase de instancia (Free Tier elegible)|

```powershell
.\create-rds.ps1
# Con parámetros personalizados:
.\create-rds.ps1 -Region us-west-2 -DbPassword "miPassword123"
```

```bash
chmod +x create-rds.sh
./create-rds.sh
```

El script imprime el **endpoint** al finalizar.

---

### `init-rds-db.ps1` / `init-rds-db.sh`

Crea el usuario `security_user`, la base de datos `security`, habilita
las extensiones necesarias y configura el parámetro GUC para RLS.

**Parámetros:**

| Parámetro       | Requerido | Descripción                          |
|-----------------|-----------|--------------------------------------|
| `-RdsEndpoint`  | Si        | Endpoint del RDS (xxxx.rds.amazonaws.com) |
| `-MasterPassword`| No       | Contraseña de `postgres` (default: `changeme_dev`) |

```powershell
.\init-rds-db.ps1 -RdsEndpoint "xxxx.rds.amazonaws.com"
```

```bash
./init-rds-db.sh xxxx.rds.amazonaws.com
```

---

### `restrict-ip.ps1`

Actualiza la IP permitida en el Security Group de RDS para que solo tu
IP pública actual tenga acceso al puerto 5432.

```powershell
.\restrict-ip.ps1 -SecurityGroupId "sg-xxxxxxxxxxxx"
```

---

## Conectar ms-security a RDS

Una vez creada la instancia, arrancar `ms-security` con el perfil `cloud-dev`:

```powershell
# Windows PowerShell
$env:SPRING_PROFILES_ACTIVE="cloud-dev"
$env:DB_HOST="xxxx.rds.amazonaws.com"
$env:DB_PASSWORD="changeme_dev"
mvn spring-boot:run
```

```bash
SPRING_PROFILES_ACTIVE=cloud-dev DB_HOST=xxxx.rds.amazonaws.com mvn spring-boot:run
```

---

## Costos estimados (Free Tier)

| Recurso                    | Costo Free Tier          | Costo fuera de Free Tier |
|----------------------------|--------------------------|--------------------------|
| `db.t3.micro` (750 h/mes)  | **$0** primer año        | ~$13/mes                 |
| Almacenamiento 20 GB gp2   | **$0** (incluido)        | ~$2.30/mes               |
| Snapshots 20 GB            | **$0** (incluido)        | ~$0.095/GB/mes           |

> El Free Tier aplica solo durante **12 meses** desde la creación de la cuenta AWS.
> Después de ese periodo, o si ya no estás en Free Tier, considerar RDS Serverless v2
> o eliminar la instancia cuando no se use.
