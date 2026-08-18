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
│   ├── docker-compose.yml
│   ├── .env.example
│   └── postgres/init/
│
├── aws/
│   ├── environments/               # Bifurcación QA vs PROD
│   │   ├── README.md               # Matriz: se crea / se omite
│   │   ├── qa/                     # Free Tier, 09:00–01:00 COT
│   │   └── prod/                   # 24/7; no copia atajos de qa/
│   └── rds/                        # Crear/init RDS edugest-dev (origen QA)
│
├── terraform/                      # IaC (prod)
└── ci-templates/                   # Plantillas CI/CD

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

## AWS — ambientes QA y producción

La cuenta AWS se parte en dos contratos. No se copian los atajos de QA a prod.

| Ambiente | Carpeta | Horario |
|----------|---------|---------|
| QA | [`aws/environments/qa/`](aws/environments/qa/) | 09:00–01:00 America/Bogota |
| Producción | [`aws/environments/prod/`](aws/environments/prod/) | 24/7 |

Matriz de qué se crea y qué se omite: [`aws/environments/README.md`](aws/environments/README.md).

```powershell
cd aws/environments/qa
.\harden-rds.ps1
.\deploy-ec2.ps1
.\apply-schedule.ps1
```

---

## AWS RDS (origen de la instancia QA)

Permite que el equipo apunte a RDS `edugest-dev` (`db_security`). La instancia se
crea una vez con estos scripts; el ambiente QA la etiqueta, le quita backups y
la programa en horario de oficina.

Guía: [`aws/rds/README.md`](aws/rds/README.md).


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
- **`aws/environments/qa/`** — Free Tier, EC2+RDS 09:00–01:00 COT
- **`aws/environments/prod/`** — contrato 24/7; no hereda scripts de qa/
- **`aws/rds/`** — crear/init de `edugest-dev` (lo consume QA)
- **`terraform/`** — módulos Terraform de producción
- **`ci-templates/`** — workflows de GitHub Actions reutilizables

---

## Contribuir

1. Clonar el repo
2. Hacer cambios en la rama `feature/<descripción>`
3. Abrir un PR hacia `main`
