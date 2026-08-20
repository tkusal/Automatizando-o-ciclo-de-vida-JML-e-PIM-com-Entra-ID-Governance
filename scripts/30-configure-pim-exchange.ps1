<#
NOTA DE SEGURANÇA
O modo padrão apenas exibe os payloads. Nenhuma elegibilidade ou ativação é
solicitada sem -Apply. A criação de elegibilidade exige uma conta administrativa.
A ativação deve ser executada pela própria pessoa elegível e seguirá a política
PIM da função, inclusive MFA, justificativa e aprovação quando configuradas.
Usuário, função e justificativas devem ser informados por quem executar o script.
Nenhuma informação de tenant, pessoa ou organização fica armazenada no arquivo.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$UserId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$RoleDisplayName,

    [ValidateRange(1, 365)]
    [int]$EligibilityDays = 90,

    [ValidateRange(1, 8)]
    [int]$ActivationHours = 2,

    [string]$EligibilityJustification,

    [string]$Justification,

    [switch]$CreateEligibility,
    [switch]$Activate,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
Import-Module Microsoft.Graph.Identity.Governance

if (-not (Get-MgContext)) {
    throw 'Conecte-se ao Graph com os escopos de PIM adequados.'
}

if (-not $CreateEligibility -and -not $Activate) {
    throw 'Informe -CreateEligibility, -Activate ou ambos.'
}

if ($CreateEligibility -and [string]::IsNullOrWhiteSpace($EligibilityJustification)) {
    throw 'Informe -EligibilityJustification ao criar uma elegibilidade.'
}

if ($Activate -and [string]::IsNullOrWhiteSpace($Justification)) {
    throw 'Informe -Justification ao solicitar uma ativação.'
}

$escapedRoleDisplayName = $RoleDisplayName.Replace("'", "''")
$role = Get-MgRoleManagementDirectoryRoleDefinition `
    -Filter "displayName eq '$escapedRoleDisplayName'" |
    Select-Object -First 1

if (-not $role) {
    throw "A definição da função '$RoleDisplayName' não foi encontrada."
}

$startDateTime = (Get-Date).ToUniversalTime()

if ($CreateEligibility) {
    $eligibilityParams = @{
        action            = 'adminAssign'
        justification     = $EligibilityJustification
        roleDefinitionId  = $role.Id
        directoryScopeId  = '/'
        principalId       = $UserId
        scheduleInfo      = @{
            startDateTime = $startDateTime
            expiration    = @{
                type        = 'AfterDateTime'
                endDateTime = $startDateTime.AddDays($EligibilityDays)
            }
        }
    }

    if (-not $Apply) {
        Write-Warning 'DRY RUN: a elegibilidade não será criada.'
        $eligibilityParams | ConvertTo-Json -Depth 10
    }
    elseif ($PSCmdlet.ShouldProcess($UserId, "Criar elegibilidade PIM para $RoleDisplayName")) {
        New-MgRoleManagementDirectoryRoleEligibilityScheduleRequest `
            -BodyParameter $eligibilityParams
    }
}

if ($Activate) {
    $activationParams = @{
        action            = 'selfActivate'
        principalId       = $UserId
        roleDefinitionId  = $role.Id
        directoryScopeId  = '/'
        justification     = $Justification
        scheduleInfo      = @{
            startDateTime = $startDateTime
            expiration    = @{
                type     = 'AfterDuration'
                duration = "PT${ActivationHours}H"
            }
        }
    }

    if (-not $Apply) {
        Write-Warning 'DRY RUN: a ativação não será solicitada.'
        $activationParams | ConvertTo-Json -Depth 10
    }
    elseif ($PSCmdlet.ShouldProcess($UserId, "Ativar $RoleDisplayName via PIM")) {
        New-MgRoleManagementDirectoryRoleAssignmentScheduleRequest `
            -BodyParameter $activationParams
    }
}
