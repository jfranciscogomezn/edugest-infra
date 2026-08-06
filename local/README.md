# Infraestructura local

Docker Compose con todos los servicios necesarios para desarrollar EduGest
sin conexión a la nube.

## Inicio rápido

```powershell
# Windows
Copy-Item .env.example .env
docker compose up -d
```

```bash
# Linux / macOS
cp .env.example .env
docker compose up -d
```

## Servicios

| Servicio      | Puerto | Descripción                          |
|---------------|--------|--------------------------------------|
| PostgreSQL 16 | 5432   | Base de datos relacional             |
| Redis 7       | 6379   | Cache / sesiones                     |
| Kafka 3 KRaft | 9092   | Mensajería / eventos                 |
| Kafka UI      | 8090   | http://localhost:8090                |
| MinIO         | 9000   | Almacenamiento S3-compatible         |
| MinIO Console | 9001   | http://localhost:9001                |
| MailHog       | 8025   | http://localhost:8025 (SMTP sandbox) |

## Reset completo

```powershell
docker compose down -v
docker compose up -d
```
