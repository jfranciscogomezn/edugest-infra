# RDS PostgreSQL -- Entorno cloud-dev

Scripts para crear y gestionar la instancia **AWS RDS PostgreSQL** usada como
base de datos compartida del equipo de desarrollo.

> `edugest-dev` es el RDS del ambiente **QA**. Tras crearlo: `aws/environments/qa/harden-rds.ps1`
> (retention 0 + tags) y `apply-schedule.ps1` (09:00–01:00 America/Bogota).
> Producción no usa esta instancia ni estos scripts. Matriz: [`../environments/README.md`](../environments/README.md).

---

## Prerrequisitos

- AWS CLI configurado (`aws configure`)
- Permisos IAM: RDS + EC2/VPC (lectura/escritura basica)
- Para `init-rds-db.*`: `psql` **o** Docker corriendo

---

## Flujo completo

```powershell
# 1) Crear instancia (~8 min)
.\create-rds.ps1

# 2) Usuario app, extensiones y GUC (BD db_security)
.\init-rds-db.ps1 -Endpoint "<endpoint-del-paso-1>" -MasterPassword "<tu-password>"

# 3) Arrancar ms-security
$env:SPRING_PROFILES_ACTIVE = "cloud-dev"
$env:DB_HOST = "<endpoint>"
$env:DB_PASSWORD = "changeme_dev"
mvn spring-boot:run
```

---

## Decisiones importantes de los scripts

| Tema | Decision | Por que |
|------|----------|---------|
| Nombre de BD | `db_security` | Convencion `db_<servicio>` (repo/servicio: security) |
| Version engine | Detectada dinamicamente | Evita hardcodear versiones inexistentes en la region |
| Clase | `db.t3.micro` + 20GB `gp2` | Elegible Free Tier |
| Acceso | Public + SG 0.0.0.0/0 | Solo desarrollo; usar `restrict-ip.ps1` despues |
| Idempotencia | Si la instancia ya existe, muestra el endpoint | Permite re-ejecutar sin romper |

---

## Scripts

### `create-rds.ps1` / `create-rds.sh`

Crea la instancia RDS PostgreSQL 16 con la BD `db_security`.

| Parametro | Default | Descripcion |
|-----------|---------|-------------|
| `-Region` | `us-east-1` | Region AWS |
| `-DbInstanceId` | `edugest-dev` | Identificador de la instancia |
| `-DbName` | `db_security` | Nombre de la BD (convencion `db_<servicio>`) |
| `-DbPassword` | (interactivo) | Password del usuario master `postgres` |

```powershell
.\create-rds.ps1
.\create-rds.ps1 -Region us-east-1 -DbPassword "MiPassword123!"
```

```bash
chmod +x create-rds.sh
./create-rds.sh --password "MiPassword123!"
```

### `init-rds-db.ps1` / `init-rds-db.sh`

Asegura la BD `db_security`, usuario `security_user`, extensiones y GUC de RLS.

| Parametro | Requerido | Descripcion |
|-----------|-----------|-------------|
| `-Endpoint` | Si | Endpoint RDS |
| `-MasterPassword` | Si | Password del usuario `postgres` |

```powershell
.\init-rds-db.ps1 -Endpoint "xxxx.us-east-1.rds.amazonaws.com" -MasterPassword "MiPassword123!"
```

```bash
./init-rds-db.sh --endpoint "xxxx.us-east-1.rds.amazonaws.com" --master-password "MiPassword123!"
```

### `restrict-ip.ps1`

Agrega tu IP actual al Security Group (y opcionalmente quita `0.0.0.0/0`).

```powershell
.\restrict-ip.ps1
.\restrict-ip.ps1 -RemoveAll
```

---

## Conectar ms-security

```powershell
$env:SPRING_PROFILES_ACTIVE = "cloud-dev"
$env:DB_HOST = "xxxx.us-east-1.rds.amazonaws.com"
$env:DB_PASSWORD = "changeme_dev"
mvn spring-boot:run
```

Flyway aplica las migraciones automaticamente al arrancar.

---

## Costos estimados (Free Tier)

| Recurso | Free Tier | Fuera de Free Tier |
|---------|-----------|--------------------|
| `db.t3.micro` 750 h/mes | $0 (12 meses) | ~$13/mes |
| 20 GB gp2 | $0 | ~$2.30/mes |

---

## Troubleshooting

| Error | Causa | Solucion |
|-------|-------|----------|
| `DBName security cannot be used` | Nombre reservado en API RDS | Usar `db_security` (scripts actualizados) |
| `Cannot find version 16.x` | Version hardcodeada inexistente | Scripts ya detectan la version |
| `Unknown options: 16.9, 16.10...` | Parsing malo de versiones en PowerShell | Scripts ya ordenan y toman una sola version |
| Timeout / connection refused en init | SG no permite tu IP o instancia no ready | Espera `available` y revisa inbound 5432 |
| Password rejected | Contiene `/` `"` `@` o < 8 chars | Usa otra contrasena |
