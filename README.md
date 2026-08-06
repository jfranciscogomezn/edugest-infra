# edugest-infra

Repositorio centralizado de infraestructura para la plataforma **EduGest**.

Separa la infraestructura del código de aplicación, permitiendo que los equipos de
backend/frontend usen los mismos scripts y configuraciones sin contaminar cada
microservicio.

---

## Estructura

```
edugest-infra/
├── local/                          # Infraestructura local (Docker Compose)
│   ├── docker-compose.yml          # PostgreSQL, Redis, Kafka, MinIO, MailHog
│   ├── .env.example                # Variables de entorno de ejemplo
│   └── postgres/
│       └── init/
│           └── 01_security_db.sql  # DB + usuario para ms-security
│
├── aws/
│   └── rds/                        # Scripts para RDS PostgreSQL en AWS
│       ├── create-rds.ps1          # Crear instancia (Windows)
│       ├── create-rds.sh           # Crear instancia (Linux/macOS)
│       ├── init-rds-db.ps1         # Inicializar DB en RDS (Windows)
│       ├── init-rds-db.sh          # Inicializar DB en RDS (Linux/macOS)
│       └── restrict-ip.ps1         # Actualizar IP permitida en Security Group
│
├── terraform/                      # (Futuro) IaC con Terraform
└── ci-templates/                   # (Futuro) Plantillas reutilizables de CI/CD
```

---

## Entorno local

### Prerrequisitos

- Docker Desktop instalado y corriendo
- PowerShell 7+ o bash

### Levantar todos los servicios

```powershell
cd local
Copy-Item .env.example .env
# Editar .env si quieres cambiar contraseñas (opcional)
docker compose up -d
```

```bash
cd local
cp .env.example .env
docker compose up -d
```

### Servicios y puertos

| Servicio     | Puerto | URL / Descripción                        |
|--------------|--------|------------------------------------------|
| PostgreSQL   | 5432   | Host `localhost`, usuario `postgres`     |
| Redis        | 6379   | Sin autenticación por defecto            |
| Kafka        | 9092   | Broker interno                           |
| Kafka UI     | 8090   | http://localhost:8090                    |
| MinIO        | 9000   | http://localhost:9000 (API S3)           |
| MinIO Console| 9001   | http://localhost:9001                    |
| MailHog      | 8025   | http://localhost:8025 (bandeja de correo)|

### Detener

```powershell
docker compose -f local/docker-compose.yml down
```

### Limpiar volúmenes (reset total)

```powershell
docker compose -f local/docker-compose.yml down -v
```

---

## AWS RDS (entorno cloud-dev compartido)

Permite que el equipo de desarrollo apunte a una instancia RDS compartida sin
necesidad de levantar PostgreSQL localmente.

Consulta la guía completa en [`aws/rds/README.md`](aws/rds/README.md).

### Flujo rápido

```powershell
# 1. Crear la instancia (solo la primera vez)
.\aws\rds\create-rds.ps1

# 2. Inicializar la base de datos
.\aws\rds\init-rds-db.ps1 -RdsEndpoint <endpoint>

# 3. Actualizar IP permitida cuando cambie
.\aws\rds\restrict-ip.ps1 -SecurityGroupId <sg-id>
```

---

## Microservicios que usan esta infraestructura

| Repositorio                                                | Descripción                        |
|------------------------------------------------------------|------------------------------------|
| [ms-security](https://github.com/francisco-gomez2101/ms-security) | Autenticación, autorización, roles |

---

## Convenciones

- **`local/`** — todo lo que corre en la máquina del desarrollador
- **`aws/`** — scripts/config para AWS (RDS, S3, SES, etc.)
- **`terraform/`** — módulos Terraform para producción/staging
- **`ci-templates/`** — workflows de GitHub Actions reutilizables

---

## Contribuir

1. Clonar el repo
2. Hacer cambios en la rama `feature/<descripción>`
3. Abrir un PR hacia `main`
