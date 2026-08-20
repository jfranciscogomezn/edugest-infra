# Contrato del ambiente PROD. No ejecutar los scripts de qa/.
# 24/7. Sin Free Tier como objetivo.

$script:EnvName = "prod"
$script:Region = "us-east-1"
$script:Project = "EduGest"
$script:Timezone = "America/Bogota"
$script:AlwaysOn = $true
$script:Compute = "ecs-fargate"
$script:RdsClass = "db.t3.small"
$script:RdsBackupRetentionDays = 7
$script:RdsMultiAz = $true
$script:NatGateway = $true
$script:Alb = $true
$script:ApiGatewayHttp = $true
$script:CloudFront = $true
$script:SecretsManager = $true
