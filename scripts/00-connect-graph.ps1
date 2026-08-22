<#
NOTA DE SEGURANÇA
Este script apenas autentica no Microsoft Graph. Ele não altera objetos.
Ele não armazena tenant, conta, domínio, credencial ou qualquer identificador.
Informe TenantId somente em tempo de execução quando isso for necessário.
Use uma conta de laboratório e conceda somente os escopos necessários.
Não use contas de emergência para administração cotidiana.
#>

[CmdletBinding()]
param(
    [string]$TenantId,

    [ValidateSet(
        'None',
        'UserProvisioning',
        'Lifecycle',
        'Entitlement',
        'PimEligibility',
        'PimActivation',
        'All'
    )]
    [string]$WriteProfile = 'None'
)

$ErrorActionPreference = 'Stop'

Import-Module Microsoft.Graph.Authentication

$scopes = [System.Collections.Generic.List[string]]@(
    'LifecycleWorkflows.Read.All',
    'EntitlementManagement.Read.All',
    'RoleManagement.Read.Directory',
    'Organization.Read.All',
    'User.Read.All',
    'Group.Read.All',
    'Application.Read.All'
)

$writeProfiles = @{
    UserProvisioning = @('User.ReadWrite.All')
    Lifecycle     = @('LifecycleWorkflows.ReadWrite.All')
    Entitlement   = @('EntitlementManagement.ReadWrite.All')
    PimEligibility = @('RoleEligibilitySchedule.ReadWrite.Directory')
    PimActivation = @('RoleAssignmentSchedule.ReadWrite.Directory')
    All           = @(
        'User.ReadWrite.All'
        'LifecycleWorkflows.ReadWrite.All'
        'EntitlementManagement.ReadWrite.All'
        'RoleEligibilitySchedule.ReadWrite.Directory'
        'RoleAssignmentSchedule.ReadWrite.Directory'
    )
}

if ($WriteProfile -ne 'None') {
    $writeProfiles[$WriteProfile] |
        ForEach-Object { $scopes.Add($_) }
}

$connectParams = @{
    Scopes       = $scopes.ToArray()
    ContextScope = 'Process'
    NoWelcome    = $true
}

if ($TenantId) {
    $connectParams.TenantId = $TenantId
}

Connect-MgGraph @connectParams
Get-MgContext | Select-Object Account, TenantId, AuthType, Scopes
