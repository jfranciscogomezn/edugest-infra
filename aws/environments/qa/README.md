# Ambiente QA (Free Tier)

Contrato: una caja, RDS ya existente, sin HA, sin backups, horario **09:00–01:00**
`America/Bogota`. Matriz completa: [../README.md](../README.md).

Perfil de aplicación: `cloud-dev` (ms-security). Login seed NORTE.
**No recrees ni termines** la instancia `edugest-qa-api`.

## Arquitectura vigente

```
Navegador
  → Amplify Hosting (SPA, HTTPS, rama qa)
  → API https://<eip-con-guiones>.sslip.io  (Caddy :443, Let's Encrypt)
  → JAR ms-security en localhost:8080  (systemd, -Xmx384m, perfil cloud-dev)
  → RDS edugest-dev / db_security
```

ms-tenant **no** corre en esta caja.

URLs de esta cuenta (región `us-east-1`):

| Qué | URL |
|-----|-----|
| Front QA | https://qa.d3gj9a8rgw3seo.amplifyapp.com |
| API | https://3-217-23-44.sslip.io/api/v1 |
| Login | `applicationCode=edugest`, `tenantCode=NORTE`, `admin.norte@edugest.qa` / `Qa@2026!`, header `X-Tenant-ID: NORTE` |

Fuera de 09:00–01:00 COT el front carga y el API no (EC2/RDS detenidos).

## Qué se hace aquí (y no en prod)

| Paso | Script | Efecto |
|------|--------|--------|
| 0 | `.\create-budget.ps1 -Email "..."` | Alerta COST 300 USD/mes (no corta el cobro) |
| 1 | `..\..\rds\create-rds.ps1` | Solo si aún no existe `edugest-dev` |
| 2 | `.\harden-rds.ps1` | Tags `Environment=qa`, backup retention **0** |
| 3 | `.\deploy-ec2.ps1` | `t3.micro` AL2023, Java 21, SSM, 8 GB |
| 4 | `.\apply-schedule.ps1` | EventBridge: RDS 08:55–01:05, EC2 09:00–01:00 |
| 5 | `.\setup-ci.ps1` | S3, OIDC GitHub, Amplify, EIP, parámetros SSM. **No destruye la EC2** |
| 6 | `.\bootstrap-ec2.ps1` | Caddy + systemd + keystore JWT por SSM en la instancia ya creada |
| 7 | GitHub Actions **Deploy QA** | Push a `ms-security`/`edugest-frontend` publica JAR y SPA |

```powershell
cd aws/environments/qa
.\create-budget.ps1 -Email "tu-correo@dominio.com"
.\harden-rds.ps1
.\deploy-ec2.ps1
.\apply-schedule.ps1
.\setup-ci.ps1
.\bootstrap-ec2.ps1
```

No recrees la EC2 para el CI. `setup-ci` le asocia un Elastic IP y amplía el instance profile.

## Pipeline GitHub Actions

Workflows: copias en [`ci-templates/`](../../../ci-templates/). En cada repo de app:
`.github/workflows/deploy-qa.yml`.

| Repo | Trigger | Resultado |
|------|---------|-----------|
| `ms-security` rama `master` | push o `workflow_dispatch` | JAR → S3 → SSM restart `ms-security` |
| `edugest-frontend` rama `main` | push o `workflow_dispatch` | `ng build --configuration=qa` → zip Amplify rama `qa` |

Usar el workflow **Deploy QA**. El job **CI** de Maven (tests) es otro archivo y no publica.

El rol OIDC es `arn:aws:iam::060704331353:role/edugest-qa-gha`. El ARN va
**en el YAML** (no en un Secret/Variable de Actions: `secrets.QA_AWS_ROLE_ARN`
llega vacío si se creó como Variable, y `secrets.*` no es legal en `if:` de job).

Trust policy: [`iam/gha-trust.json`](iam/gha-trust.json). Incluye `sub` clásico e
**inmutable** (`repo:owner@id/repo@id:*`). GitHub emite el formato inmutable en
repos creados o renombrados después del 15-jul-2026 (`edugest-frontend`);
`ms-security` (13-jul-2026) sigue el formato clásico.

### Amplify SPA

`setup-ci.ps1` deja la rewrite `/<*>` → `/index.html` con status **404-200**.
Status **200** reescribe también los `.js`/`.css` y deja la SPA en blanco.
Tras cambiar la regla, un nuevo deploy de Amplify invalida la caché de CloudFront.

### Keystore JWT en la EC2

El `.p12` de `src/main/resources/keystore/` no entra en el JAR (`.gitignore`).
`bootstrap-ec2.ps1` / `files/install-runtime.sh` generan
`/opt/edugest/keystore/ms-security.p12` (alias `ms-security`) si no existe y
exportan:

```
APP_SECURITY_JWT_KEYSTORE_PATH=file:/opt/edugest/keystore/ms-security.p12
JWT_KEYSTORE_PASSWORD=changeme_local
```

Sin ese archivo el servicio entra en crash loop (`Failed to load JWT keystore`)
y Caddy responde **502** al preflight OPTIONS del login.

Parámetros SSM (prefijo `/edugest/qa/`): `api-base-url`, `api-hostname`,
`frontend-url`, `cors-origins`, `amplify-app-id`, `artifact-bucket`,
`instance-id`, `db-host`, `db-password` (SecureString).

## Horario

| Recurso | Arranque | Parada |
|---------|----------|--------|
| RDS `edugest-dev` | 08:55 | 01:05 |
| EC2 `edugest-qa-api` | 09:00 | 01:00 |
| Amplify / SES | Siempre | — |

QA puede trabajar de 09:00 a 01:00 COT. A las 01:05 el API y la base están apagados.
RDS detenido más de 7 días lo reanuda AWS; el schedule de las 08:55 lo vuelve a dejar en el ciclo diario.

Para quitar solo el horario (no borra RDS/EC2):

```powershell
.\remove-schedule.ps1
```

## Qué se omite (está en prod)

NAT, ALB, Fargate, API Gateway, CloudFront de producto, Route 53, Secrets Manager, Multi-AZ,
backups, segunda AZ, ms-tenant, WAF. No copiar esta carpeta a prod.

## RAM

`t3.micro` = 1 GB. Heap `-Xmx384m`. No instalar Postgres ni ms-tenant en esta instancia.
Si hay OOM: no pasar a Fargate; el escape de QA es `t3.small` (sale de Free Tier).
