<#
NOTA DE SEGURANÇA
O modo padrão apenas exibe o payload. Nenhum workflow é criado sem -Apply.
As tarefas desabilitam contas, invalidam sessões e removem licenças diretas.
Teste com uma identidade descartável e mantenha o agendamento desligado inicialmente.
Departamento e demais dados contextuais são recebidos em tempo de execução.
Os GUIDs das tarefas são identificadores públicos de definições nativas da
Microsoft, não identificadores de tenant, usuários ou clientes.
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

$params = @{
    category            = 'leaver'
    displayName         = "JML | Offboarding | $Department"
    description         = 'Bloqueia a conta, revoga tokens e remove licenças diretas na data de saída.'
    isEnabled           = $true
    isSchedulingEnabled = [bool]$EnableSchedule
    executionConditions = @{
        '@odata.type' = '#microsoft.graph.identityGovernance.triggerAndScopeBasedConditions'
        scope         = @{
            '@odata.type' = '#microsoft.graph.identityGovernance.ruleBasedSubjectSet'
            rule          = "(department eq '$Department')"
        }
        trigger       = @{
            '@odata.type'      = '#microsoft.graph.identityGovernance.timeBasedAttributeTrigger'
            timeBasedAttribute = 'employeeLeaveDateTime'
            offsetInDays       = 0
        }
    }
    tasks               = @(
        @{
            category         = 'leaver'
            continueOnError  = $false
            description      = 'Desabilita a conta no diretório.'
            displayName      = 'Disable user account'
            executionSequence = 1
            isEnabled        = $true
            taskDefinitionId = '1dfdfcc7-52fa-4c2e-bf3a-e3919cc12950'
            arguments        = @()
        },
        @{
            category         = 'leaver'
            continueOnError  = $true
            description      = 'Revoga tokens de atualização e sessões de navegador.'
            displayName      = 'Revoke all refresh tokens for user'
            executionSequence = 2
            isEnabled        = $true
            taskDefinitionId = '509589a4-0466-4471-829e-49c5e502bdee'
            arguments        = @()
        },
        @{
            category         = 'leaver'
            continueOnError  = $true
            description      = 'Remove todas as licenças atribuídas diretamente à pessoa.'
            displayName      = 'Remove all licenses for user'
            executionSequence = 3
            isEnabled        = $true
            taskDefinitionId = '8fa97d28-3e52-4985-b3a9-a1126f9b8b4e'
            arguments        = @()
        }
    )
}

if (-not $Apply) {
    Write-Warning 'DRY RUN: o workflow não será criado. Revise o payload abaixo.'
    $params | ConvertTo-Json -Depth 12
    return
}

if ($PSCmdlet.ShouldProcess($params.displayName, 'Criar Lifecycle Workflow de Leaver')) {
    New-MgIdentityGovernanceLifecycleWorkflow -BodyParameter $params
}
