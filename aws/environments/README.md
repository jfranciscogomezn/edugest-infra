# Ambientes AWS — QA vs producción

Dos carpetas, dos contratos. Lo que se crea en **qa** no se replica en **prod**.
Lo que exige **prod** no se monta en **qa**.

| Ambiente | Carpeta | Spring / front | Horario (America/Bogota) |
|----------|---------|----------------|--------------------------|
| QA | [`qa/`](qa/) | Perfil `cloud-dev` + Amplify o Caddy | **09:00 → 01:00** (16 h up) |
| Producción | [`prod/`](prod/) | Perfil de runtime de producto | **24/7** |

Zona horaria: `America/Bogota` (COT, UTC−5). Arranque 09:00, parada 01:00 del día siguiente.
Fuera de esa ventana el API y RDS de QA están detenidos; Amplify y SES siguen disponibles
(el front muestra error de API).

---

## Matriz: se crea / se omite

Leyenda: **Sí** = se crea en ese ambiente. **No** = se omite a propósito.

| Recurso | QA | PROD | Motivo de la omisión |
|---------|----|------|----------------------|
| VPC nueva (2 AZ, NAT, subnets privadas) | No | Sí | QA usa la VPC por defecto; NAT ~34 USD |
| NAT Gateway | No | Sí | EC2 y RDS públicos en QA |
| Application Load Balancer | No | Sí | Un solo nodo QA; Caddy o :8080 |
| ECS Fargate | No | Sí | Un `t3.micro` con el JAR |
| EC2 `t3.micro` (ms-security) | Sí | No | Prod no corre la API en una caja pública |
| API Gateway HTTP + VPC Link | No | Sí | nginx/Caddy en QA |
| CloudFront + S3 + ACM + Route 53 | No | Sí | Amplify (o Caddy) en QA |
| Amplify Hosting (SPA) | Sí | No | Prod usa CloudFront |
| RDS `db.t3.micro` (`edugest-dev`, `db_security`) | Sí (reusa) | No | Prod: instancia propia, privada, clase mayor |
| RDS Multi-AZ | No | Sí | QA no pide HA |
| RDS backups (retention) | **0 días** | ≥ 7 días | Seed SQL rehace QA |
| RDS / EC2 horario 09:00–01:00 | Sí | No | Prod no se apaga |
| IPv4 público en el cómputo | Sí | No | Prod: egress por NAT, API interna |
| Secrets Manager | No | Sí | QA: SSM Parameter Store (0 USD) |
| SSM Parameter Store + Session Manager | Sí | Sí | En prod es complemento, no el único secreto |
| SES Mail Manager | Sí (reusa) | Sí (cuenta/prod) | Ya existe; no recrear |
| CloudWatch Logs retenidos | journalctl / 3 días | 14+ días | QA no paga ingesta extra |
| WAF | No | Sí | Fuera de alcance QA |
| ms-tenant / `db_tenant` / 2.ª instancia | No | Sí | QA de login y admin UX usa ms-security |
| ElastiCache / MSK / EKS | No | Según carga | Fuera de este corte |

Fuente de costo QA: IPv4 público (~4 USD/mes) + RDS/EC2 si el Free Tier ya venció.
Prod no hereda el recorte Free Tier.

---

## Flujo de trabajo

```
1. QA (ahora)
   aws/environments/qa/harden-rds.ps1      # retention 0, tags Environment=qa
   aws/environments/qa/deploy-ec2.ps1      # t3.micro + SSM
   aws/environments/qa/apply-schedule.ps1  # EventBridge 09:00 / 01:00 COT
   Front: Amplify apuntando al API_URL de esa EC2

2. PROD (cuando haya cliente que pague)
   No copiar scripts de qa/.
   Seguir aws/environments/prod/README.md (VPC privada, Fargate, ALB, backups).
```

Los scripts de [`aws/rds/`](../rds/) siguen siendo el origen de la instancia
`edugest-dev`. Esta carpeta no la recrea; la etiqueta y la programa.

---

## Tags comunes

| Tag | QA | PROD |
|-----|----|------|
| `Project` | `EduGest` | `EduGest` |
| `Environment` | `qa` | `prod` |
| `Schedule` | `office-hours` | `always-on` |
