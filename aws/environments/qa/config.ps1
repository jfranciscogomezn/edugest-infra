# Contrato del ambiente QA. Dot-source desde los otros scripts de esta carpeta.
# Horario: 09:00 arranque, 01:00 parada, America/Bogota.

$script:EnvName = "qa"
$script:Region = "us-east-1"
$script:Project = "EduGest"
$script:Timezone = "America/Bogota"
$script:StartCron = "cron(0 9 * * ? *)"
$script:StopCron = "cron(0 1 * * ? *)"
$script:RdsInstanceId = "edugest-dev"
$script:Ec2Name = "edugest-qa-api"
$script:ScheduleGroup = "edugest-qa"
$script:SchedulerRoleName = "edugest-qa-scheduler-role"
$script:InstanceProfileName = "edugest-qa-ec2-ssm"
$script:ApiSgName = "edugest-qa-api-sg"
$script:InstanceType = "t3.micro"
$script:RootVolumeGb = 8
