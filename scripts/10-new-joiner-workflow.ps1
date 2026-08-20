<#
NOTA DE SEGURANÇA
O modo padrão apenas exibe o payload. Nenhum workflow é criado sem -Apply.
Departamento e demais dados contextuais são recebidos em tempo de execução.
Mesmo com -Apply, o agendamento permanece desligado sem -EnableSchedule.
Valide o filtro, o atributo employeeHireDate e a conta do gestor em laboratório.
O GUID da tarefa é um identificador público de definição nativa da Microsoft,
não um identificador de tenant, usuário ou cliente.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Department,

    [switch]$EnableSchedule,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
Import-Module Microsoft.Graph.Identity.Governance

if ($Department.Contains("'")) {
    throw 'Department não pode conter apóstrofo neste exemplo didático.'
}

if (-not (Get-MgContext)) {
    throw 'Conecte-se primeiro com LifecycleWorkflows.ReadWrite.All.'
}

$tapTaskDefinitionId = '1b555e50-7f65-41d5-b514-5894a026d10d'
$taskDefinition = Get-MgIdentityGovernanceLifecycleWorkflowTaskDefinition `
    -TaskDefinitionId $tapTaskDefinitionId

$params = @{
    category            = 'joiner'
    displayName         = "JML | Onboarding | $Department"
    description         = 'Gera TAP no primeiro dia e envia o passe ao gestor da pessoa contratada.'
    isEnabled           = $true
    isSchedulingEnabled = [bool]$EnableSchedule
    executionConditions = @{
        '@odata.type' = '#microsoft.graph.identityGovernance.triggerAndScopeBasedConditions'
        scope         = @{
            '@odata.type' = '#microsoft.graph.identityGovernance.ruleBasedSubjectSet'
            rule          = "(department eq '$Department')"
        }
        trigger       = @{
            '@odata.type'     = '#microsoft.graph.identityGovernance.timeBasedAttributeTrigger'
            timeBasedAttribute = 'employeeHireDate'
            offsetInDays       = 0
        }
    }
    tasks               = @(
        @{
            category         = 'joiner'
            continueOnError  = $false
            description      = 'Gera um Temporary Access Pass e envia por email ao gestor.'
            displayName      = $taskDefinition.DisplayName
            executionSequence = 1
            isEnabled        = $true
            taskDefinitionId = $tapTaskDefinitionId
            arguments        = @(
                @{
                    name  = 'tapLifetimeMinutes'
                    value = '480'
                },
                @{
                    name  = 'tapIsUsableOnce'
                    value = 'true'
                }
            )
        }
    )
}

if (-not $Apply) {
    Write-Warning 'DRY RUN: o workflow não será criado. Revise o payload abaixo.'
    $params | ConvertTo-Json -Depth 12
    return
}

if ($PSCmdlet.ShouldProcess($params.displayName, 'Criar Lifecycle Workflow de Joiner')) {
    New-MgIdentityGovernanceLifecycleWorkflow -BodyParameter $params
}
