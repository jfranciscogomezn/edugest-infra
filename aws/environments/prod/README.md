# Ambiente producción

Contrato opuesto a QA. **No** se usan los scripts de `qa/`.
Matriz: [../README.md](../README.md).

Prod corre **24/7**. No hay EventBridge de start/stop. No hay `t3.micro` público
como runtime de la API.

## Qué se crea aquí (y se omite en QA)

| Recurso | En prod | En QA |
|---------|---------|-------|
| VPC 2 AZ + subnets privadas | Sí | No (VPC default) |
| NAT Gateway (1 AZ mínimo) | Sí | No |
| ALB interno | Sí | No |
| ECS Fargate (ms-security; luego ms-tenant) | Sí | No |
| API Gateway HTTP + VPC Link | Sí | No |
| CloudFront + S3 + ACM | Sí | No (Amplify) |
| RDS privado, Multi-AZ, retention ≥ 7 | Sí | No |
| Secrets Manager | Sí | No (SSM) |
| Horario 09:00–01:00 | **No** | Sí |

## Qué se omite aquí (atajos solo de QA)

| Atajo QA | Por qué prod no lo copia |
|----------|--------------------------|
| EC2 `t3.micro` con IP pública | Superficie de ataque y un solo punto de falla |
| RDS público + backup retention 0 | Pérdida de datos y exposición 5432 |
| Amplify como origen de producto | Sin WAF/OAC ni dominio de marca unificado |
| Apagar cómputo de noche | Colegios y jobs no caben en 09:00–01:00 |
| JAR copiado a mano por SSM | Deploy por imagen ECR + rolling |
| SG 0.0.0.0/0 a 8080 | Ingress solo ALB / API Gateway |

## Runtime

Perfil Spring de producto (no `cloud-dev`). IaC de esta carpeta: Terraform bajo
`terraform/` cuando se adopte; hasta entonces este README es el contrato para no
copiar `qa/` a la cuenta de producción.
