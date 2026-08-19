# Ambiente QA (Free Tier)

Contrato: una caja, RDS ya existente, sin HA, sin backups, horario **09:00–01:00**
`America/Bogota`. Matriz completa: [../README.md](../README.md).

Perfil de aplicación: `cloud-dev` (ms-security). Login seed NORTE.

## Qué se hace aquí (y no en prod)

| Paso | Script | Efecto |
|------|--------|--------|
| 0 | `.\create-budget.ps1 -Email "..."` | Alerta COST 300 USD/mes (no corta el cobro) |
| 1 | `..\..\rds\create-rds.ps1` | Solo si aún no existe `edugest-dev` |
| 2 | `.\harden-rds.ps1` | Tags `Environment=qa`, backup retention **0** |
| 3 | `.\deploy-ec2.ps1` | `t3.micro` AL2023, Java 21, SSM, 8 GB |
| 4 | `.\apply-schedule.ps1` | EventBridge: RDS 08:55–01:05, EC2 09:00–01:00 |
| 5 | `.\setup-ci.ps1` | S3, OIDC GitHub, Amplify, EIP, parametros SSM. **No destruye la EC2** |
| 6 | `.\bootstrap-ec2.ps1` | Caddy + systemd por SSM en la instancia ya creada |
| 7 | GitHub Actions | Push a `ms-security`/`edugest-frontend` publica JAR y SPA |

```powershell
cd aws/environments/qa
.\create-budget.ps1 -Email "tu-correo@dominio.com"
.\harden-rds.ps1
.\deploy-ec2.ps1
.\apply-schedule.ps1
.\setup-ci.ps1
.\bootstrap-ec2.ps1
```

No recrees la EC2 para el CI. `setup-ci` le asocia un Elastic IP y amplia el instance profile.

Secret unico en **ambos** repos (`ms-security` y `edugest-frontend`):

`QA_AWS_ROLE_ARN` = `arn:aws:iam::<cuenta>:role/edugest-qa-gha`

(el script lo imprime). Luego:

- Push a `master` en ms-security → JAR a S3 + restart `ms-security` por SSM
- Push a `main` en edugest-frontend → `ng build --configuration=qa` + Amplify

El API queda en `https://<eip-con-guiones>.sslip.io/api/v1` (Caddy, Let's Encrypt). El front en `https://qa.<appId>.amplifyapp.com`.

Para quitar solo el horario (no borra RDS/EC2):

```powershell
.\remove-schedule.ps1
```

## Horario

| Recurso | Arranque | Parada |
|---------|----------|--------|
| RDS `edugest-dev` | 08:55 | 01:05 |
| EC2 `edugest-qa-api` | 09:00 | 01:00 |
| Amplify / SES | Siempre | — |

QA puede trabajar de 09:00 a 01:00 COT. A las 01:05 el API y la base están apagados.
RDS detenido más de 7 días lo reanuda AWS; el schedule de las 08:55 lo vuelve a dejar en el ciclo diario.

## Qué se omite (está en prod)

NAT, ALB, Fargate, API Gateway, CloudFront, Route 53, Secrets Manager, Multi-AZ,
backups, segunda AZ, ms-tenant, WAF. No copiar esta carpeta a prod.

## RAM

`t3.micro` = 1 GB. Heap `-Xmx384m`. No instalar Postgres ni ms-tenant en esta instancia.
Si hay OOM: no pasar a Fargate; el escape de QA es `t3.small` (sale de Free Tier).
