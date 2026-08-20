<#
NOTA DE SEGURANÇA
O modo padrão somente mostra a configuração proposta. Nenhuma política é alterada
sem -Apply. O comportamento padrão mantém o acesso quando não há resposta.
Use removeAccess somente após validar gestores, fallback e notificações.
IDs, revisor e data são fornecidos em tempo de execução. A URL fixa pertence ao
endpoint público do Microsoft Graph e não identifica um tenant.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$AssignmentPolicyId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$AccessPackageId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$FallbackReviewerUserId,

    [datetime]$ReviewStartDate = (Get-Date).Date.AddDays(7),

    [ValidateSet('keepAccess', 'removeAccess', 'acceptAccessRecommendation')]
    [string]$ExpirationBehavior = 'keepAccess',

    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
Import-Module Microsoft.Graph.Authentication

if (-not (Get-MgContext)) {
    throw 'Conecte-se primeiro com EntitlementManagement.ReadWrite.All.'
}

$encodedExpand = [uri]::EscapeDataString('accessPackage')
$uri = "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/assignmentPolicies/$AssignmentPolicyId`?`$expand=$encodedExpand"
$policy = Invoke-MgGraphRequest -Method GET -Uri $uri

$reviewSettings = @{
    isEnabled                       = $true
    expirationBehavior              = $ExpirationBehavior
    isRecommendationEnabled         = $true
    isReviewerJustificationRequired = $true
    isSelfReview                    = $false
    primaryReviewers                = @(
        @{
            '@odata.type' = '#microsoft.graph.requestorManager'
            managerLevel  = 1
        }
    )
    fallbackReviewers               = @(
        @{
            '@odata.type' = '#microsoft.graph.singleUser'
            userId        = $FallbackReviewerUserId
        }
    )
    schedule                        = @{
        startDateTime = $ReviewStartDate.ToUniversalTime().ToString('o')
        expiration    = @{
            type     = 'afterDuration'
            duration = 'P14D'
        }
        recurrence    = @{
            pattern = @{
                type       = 'absoluteMonthly'
                interval   = 3
                dayOfMonth = $ReviewStartDate.Day
            }
            range   = @{
                type      = 'noEnd'
                startDate = $ReviewStartDate.ToString('yyyy-MM-dd')
            }
        }
    }
}

$body = @{
    id                      = $AssignmentPolicyId
    displayName             = $policy.displayName
    description             = $policy.description
    allowedTargetScope      = $policy.allowedTargetScope
    automaticRequestSettings = $policy.automaticRequestSettings
    specificAllowedTargets  = @($policy.specificAllowedTargets)
    expiration              = $policy.expiration
    requestorSettings       = $policy.requestorSettings
    requestApprovalSettings = $policy.requestApprovalSettings
    reviewSettings          = $reviewSettings
    questions               = @($policy.questions)
    accessPackage           = @{ id = $AccessPackageId }
}

if (-not $Apply) {
    Write-Warning 'DRY RUN: a política não será atualizada. Revise o payload abaixo.'
    $body | ConvertTo-Json -Depth 20
    return
}

if ($PSCmdlet.ShouldProcess($AssignmentPolicyId, 'Habilitar revisão trimestral do pacote')) {
    $putUri = "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/assignmentPolicies/$AssignmentPolicyId"
    Invoke-MgGraphRequest `
        -Method PUT `
        -Uri $putUri `
        -Body ($body | ConvertTo-Json -Depth 20) `
        -ContentType 'application/json'
}
