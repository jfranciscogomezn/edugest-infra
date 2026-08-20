# Plantillas CI/CD — Deploy QA

Copias de los workflows vigentes. La fuente que GitHub ejecuta vive en cada
repo de aplicación (`.github/workflows/deploy-qa.yml`).

| Plantilla | Repo destino | Rama que dispara |
|-----------|--------------|------------------|
| `ms-security-deploy-qa.yml` | [ms-security](https://github.com/jfranciscogomezn/ms-security) | `master` |
| `edugest-frontend-deploy-qa.yml` | [edugest-frontend](https://github.com/jfranciscogomezn/edugest-frontend) | `main` |

Contrato del ambiente, OIDC y URLs: [`aws/environments/qa/README.md`](../aws/environments/qa/README.md).

## Qué hace cada workflow

**ms-security — Deploy QA (no el job CI de tests)**

1. `mvn -DskipTests package`
2. OIDC al rol `edugest-qa-gha`
3. Copia el JAR a S3 y, por SSM, lo instala en `/opt/edugest/ms-security.jar` y reinicia `systemd`

**edugest-frontend — Deploy QA**

1. Lee `/edugest/qa/api-base-url` y lo inyecta en `environment.qa.ts`
2. `ng build --configuration=qa`
3. Zip de `dist/edugest-frontend/browser` → Amplify Hosting, rama `qa`

## OIDC

El ARN del rol va **hardcodeado** en el YAML. GitHub no permite `secrets.*` en
un `if:` de job, y una Variable de Actions no rellena `secrets.QA_AWS_ROLE_ARN`
(queda vacío y el assume-role falla).

La trust policy (`aws/environments/qa/iam/gha-trust.json`) acepta el `sub` clásico
(`repo:owner/repo:*`) y el formato inmutable de GitHub (repos creados después del
15-jul-2026: `repo:owner@ownerId/repo@repoId:*`). `edugest-frontend` usa el
formato inmutable; `ms-security` (creado antes) usa el clásico.

`permissions: id-token: write` es obligatorio. El job **no** declara
`environment:` de GitHub: si se añade, el `sub` pasa a `…:environment:NOMBRE` y
hay que ampliar la trust policy.
