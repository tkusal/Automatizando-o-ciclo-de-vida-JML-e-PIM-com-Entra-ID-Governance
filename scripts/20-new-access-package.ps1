<#
NOTA DE SEGURANÇA
O modo padrão somente consulta o catálogo e exibe payloads. Nenhum recurso, pacote
ou política é criado sem -Apply. Revise IDs, funções de recurso, gestor e aprovador
de fallback em um tenant de laboratório. O script não cria grupos, sites ou apps.
Todos os IDs, URLs, nomes e funções de negócio são fornecidos por parâmetros.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$CatalogId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$GroupId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$ApplicationServicePrincipalId,

    [Parameter(Mandatory)]
    [ValidatePattern('^https://')]
    [string]$SharePointSiteUrl,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$FallbackApproverUserId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$AccessPackageName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ApplicationRoleName,

    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
Import-Module Microsoft.Graph.Identity.Governance

if (-not (Get-MgContext)) {
    throw 'Conecte-se primeiro com EntitlementManagement.ReadWrite.All.'
}

$null = Get-MgEntitlementManagementCatalog -AccessPackageCatalogId $CatalogId

$resourceDescriptors = @(
    [pscustomobject]@{
        Label        = 'Grupo do Teams'
        OriginId     = $GroupId
        OriginSystem = 'AadGroup'
        RoleName     = 'Member'
    },
    [pscustomobject]@{
        Label        = 'Aplicativo corporativo'
        OriginId     = $ApplicationServicePrincipalId
        OriginSystem = 'AadApplication'
        RoleName     = $ApplicationRoleName
    },
    [pscustomobject]@{
        Label        = 'Site do SharePoint'
        OriginId     = $SharePointSiteUrl.TrimEnd('/')
        OriginSystem = 'SharePointOnline'
        RoleName     = 'Member'
    }
)

function Get-CatalogResource {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Descriptor
    )

    Get-MgEntitlementManagementCatalogResource `
        -AccessPackageCatalogId $CatalogId `
        -ExpandProperty scopes `
        -All |
        Where-Object {
            $_.OriginId -eq $Descriptor.OriginId -and
            $_.OriginSystem -eq $Descriptor.OriginSystem
        } |
        Select-Object -First 1
}

function Resolve-CatalogResource {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Descriptor
    )

    $resource = Get-CatalogResource -Descriptor $Descriptor
    if ($resource) {
        return $resource
    }

    $requestParams = @{
        requestType = 'adminAdd'
        resource    = @{
            originId     = $Descriptor.OriginId
            originSystem = $Descriptor.OriginSystem
        }
        catalog     = @{ id = $CatalogId }
    }

    if (-not $Apply) {
        Write-Warning "DRY RUN: $($Descriptor.Label) ainda não está no catálogo."
        $requestParams | ConvertTo-Json -Depth 8
        return $null
    }

    if (-not $PSCmdlet.ShouldProcess($Descriptor.OriginId, "Adicionar $($Descriptor.Label) ao catálogo")) {
        return $null
    }

    $null = New-MgEntitlementManagementResourceRequest -BodyParameter $requestParams

    for ($attempt = 1; $attempt -le 10; $attempt++) {
        Start-Sleep -Seconds 3
        $resource = Get-CatalogResource -Descriptor $Descriptor
        if ($resource) {
            return $resource
        }
    }

    throw "$($Descriptor.Label) não ficou disponível no catálogo após 30 segundos."
}

function Add-ResourceRoleScope {
    param(
        [Parameter(Mandatory)]
        [string]$AccessPackageId,

        [Parameter(Mandatory)]
        [pscustomobject]$Descriptor,

        [Parameter(Mandatory)]
        [object]$Resource
    )

    $filter = "(originSystem eq '$($Descriptor.OriginSystem)' and resource/id eq '$($Resource.Id)')"
    $roles = @(
        Get-MgEntitlementManagementCatalogResourceRole `
            -AccessPackageCatalogId $CatalogId `
            -Filter $filter `
            -ExpandProperty resource `
            -All
    )

    $selectedRole = $roles |
        Where-Object DisplayName -eq $Descriptor.RoleName |
        Select-Object -First 1

    if (-not $selectedRole) {
        $available = ($roles.DisplayName | Sort-Object -Unique) -join ', '
        throw "Função '$($Descriptor.RoleName)' não encontrada em $($Descriptor.Label). Disponíveis: $available"
    }

    $scope = @($Resource.Scopes) | Select-Object -First 1
    if (-not $scope) {
        throw "Nenhum escopo foi localizado para $($Descriptor.Label)."
    }

    $roleScopeParams = @{
        role  = @{
            id           = $selectedRole.Id
            displayName  = $selectedRole.DisplayName
            description  = $selectedRole.Description
            originSystem = $selectedRole.OriginSystem
            originId     = $selectedRole.OriginId
            resource     = @{
                id           = $Resource.Id
                originId     = $Resource.OriginId
                originSystem = $Resource.OriginSystem
            }
        }
        scope = @{
            id           = $scope.Id
            originId     = $scope.OriginId
            originSystem = $scope.OriginSystem
        }
    }

    if ($PSCmdlet.ShouldProcess($Descriptor.Label, "Associar função ao pacote $AccessPackageName")) {
        New-MgEntitlementManagementAccessPackageResourceRoleScope `
            -AccessPackageId $AccessPackageId `
            -BodyParameter $roleScopeParams
    }
}

$resolvedResources = [System.Collections.Generic.List[object]]::new()
foreach ($descriptor in $resourceDescriptors) {
    $resource = Resolve-CatalogResource -Descriptor $descriptor
    if ($resource) {
        $resolvedResources.Add([pscustomobject]@{
            Descriptor = $descriptor
            Resource   = $resource
        })
    }
}

$packageParams = @{
    displayName = $AccessPackageName
    description = "Acesso governado para o pacote $AccessPackageName."
    isHidden    = $false
    catalog     = @{ id = $CatalogId }
}

$packageIdForPreview = '<ACCESS_PACKAGE_ID_CREATED_ON_APPLY>'
$policyParams = @{
    displayName           = 'Autoatendimento interno com aprovação do gestor'
    description           = 'Pessoas internas podem solicitar acesso por 180 dias, sujeito à aprovação.'
    allowedTargetScope    = 'allMemberUsers'
    specificAllowedTargets = @()
    expiration            = @{
        type     = 'afterDuration'
        duration = 'P180D'
    }
    requestorSettings     = @{
        enableTargetsToSelfAddAccess             = $true
        enableTargetsToSelfUpdateAccess          = $true
        enableTargetsToSelfRemoveAccess          = $true
        allowCustomAssignmentSchedule            = $false
        enableOnBehalfRequestorsToAddAccess       = $false
        enableOnBehalfRequestorsToUpdateAccess    = $false
        enableOnBehalfRequestorsToRemoveAccess    = $false
        onBehalfRequestors                        = @()
    }
    requestApprovalSettings = @{
        isApprovalRequiredForAdd    = $true
        isApprovalRequiredForUpdate = $true
        stages                      = @(
            @{
                durationBeforeAutomaticDenial  = 'P5D'
                isApproverJustificationRequired = $true
                isEscalationEnabled             = $false
                durationBeforeEscalation        = 'PT0S'
                primaryApprovers                = @(
                    @{
                        '@odata.type' = '#microsoft.graph.requestorManager'
                        managerLevel  = 1
                    }
                )
                fallbackPrimaryApprovers        = @(
                    @{
                        '@odata.type' = '#microsoft.graph.singleUser'
                        userId        = $FallbackApproverUserId
                    }
                )
                escalationApprovers             = @()
                fallbackEscalationApprovers     = @()
            }
        )
    }
    accessPackage         = @{ id = $packageIdForPreview }
}

if (-not $Apply) {
    Write-Warning 'DRY RUN: o pacote e a política não serão criados.'
    [pscustomobject]@{
        AccessPackage = $packageParams
        AssignmentPolicy = $policyParams
        ResourcesAlreadyResolved = $resolvedResources.Count
    } | ConvertTo-Json -Depth 20
    return
}

if ($resolvedResources.Count -ne $resourceDescriptors.Count) {
    if ($WhatIfPreference) {
        Write-Warning 'WHATIF: recursos ausentes seriam adicionados antes da criação do pacote.'
        return
    }
    throw 'Nem todos os recursos foram resolvidos no catálogo.'
}

if (-not $PSCmdlet.ShouldProcess($AccessPackageName, 'Criar pacote de acesso')) {
    return
}

$accessPackage = New-MgEntitlementManagementAccessPackage -BodyParameter $packageParams

foreach ($resolved in $resolvedResources) {
    Add-ResourceRoleScope `
        -AccessPackageId $accessPackage.Id `
        -Descriptor $resolved.Descriptor `
        -Resource $resolved.Resource
}

$policyParams.accessPackage.id = $accessPackage.Id
$assignmentPolicy = $null
if ($PSCmdlet.ShouldProcess($accessPackage.Id, 'Criar política de solicitação e aprovação')) {
    $assignmentPolicy = New-MgEntitlementManagementAssignmentPolicy `
        -BodyParameter $policyParams
}

[pscustomobject]@{
    AccessPackageId    = $accessPackage.Id
    AssignmentPolicyId = $assignmentPolicy.Id
}
