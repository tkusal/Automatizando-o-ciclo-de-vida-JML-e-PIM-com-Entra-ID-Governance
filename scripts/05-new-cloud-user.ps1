<#
NOTA DE SEGURANÇA
O modo padrão apenas exibe um payload anonimizado. Nenhum usuário é criado sem -Apply.
Todos os dados de pessoa, domínio, departamento, gestor e chamado são recebidos em tempo de execução.
A senha temporária é gerada somente durante a aplicação, não é exibida e não é armazenada.
Use este script apenas para identidades cloud-only de laboratório.
Em produção, prefira provisionamento orientado pela fonte autorizada de RH ou IAM.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [ValidateLength(3, 64)]
    [string]$RequestId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$UserPrincipalName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$DisplayName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$GivenName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Surname,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$JobTitle,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Department,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z]{2}$')]
    [string]$UsageLocation,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ManagerUserId,

    [Parameter(Mandatory)]
    [datetimeoffset]$EmployeeHireDate,

    [string]$MailNickname,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
Import-Module Microsoft.Graph.Users
Import-Module Microsoft.Graph.Identity.DirectoryManagement

function New-RandomTemporaryPassword {
    # NewGuid fornece entropia suficiente para o laboratório. Os caracteres
    # adicionais garantem variedade de classes sem persistir a senha.
    return '{0}aA1!' -f ([guid]::NewGuid().ToString('N'))
}

$context = Get-MgContext
if (-not $context) {
    throw 'Conecte-se primeiro com o perfil UserProvisioning.'
}

if ($context.Scopes -notcontains 'User.ReadWrite.All') {
    throw 'Conecte-se primeiro com User.ReadWrite.All.'
}

if ($UserPrincipalName -notmatch '^[^@\s]+@[^@\s]+$') {
    throw 'UserPrincipalName deve usar o formato alias@dominio-verificado.'
}

$upnParts = $UserPrincipalName.Split('@')
$upnDomain = $upnParts[-1]

if (-not $MailNickname) {
    $MailNickname = $upnParts[0] -replace '[^A-Za-z0-9]', ''
}

if (-not $MailNickname) {
    throw 'Não foi possível derivar MailNickname. Informe o parâmetro explicitamente.'
}

$organization = Get-MgOrganization -Property VerifiedDomains | Select-Object -First 1
$verifiedDomain = @($organization.VerifiedDomains) |
    Where-Object { $_.Name -ieq $upnDomain -and $_.IsVerified } |
    Select-Object -First 1

if (-not $verifiedDomain) {
    throw "O domínio '$upnDomain' não aparece como verificado no tenant conectado."
}

$escapedUpn = $UserPrincipalName.Replace("'", "''")
$existingUser = Get-MgUser -Filter "userPrincipalName eq '$escapedUpn'" -Top 1
if ($existingUser) {
    throw "Já existe um usuário com o UPN '$UserPrincipalName'."
}

$manager = Get-MgUser -UserId $ManagerUserId -Property Id,DisplayName,Mail,UserPrincipalName
if (-not $manager.Mail) {
    throw 'O gestor informado não possui o atributo mail preenchido para receber o TAP.'
}

$userParams = [ordered]@{
    accountEnabled    = $true
    displayName       = $DisplayName
    givenName         = $GivenName
    surname           = $Surname
    userPrincipalName = $UserPrincipalName
    mailNickname      = $MailNickname
    jobTitle          = $JobTitle
    department        = $Department
    employeeType      = 'Employee'
    employeeHireDate  = $EmployeeHireDate.ToUniversalTime().ToString('o')
    usageLocation     = $UsageLocation.ToUpperInvariant()
    passwordProfile   = @{
        forceChangePasswordNextSignIn = $true
        password                      = '<GENERATED_ONLY_DURING_APPLY>'
    }
}

if (-not $Apply) {
    Write-Warning 'DRY RUN: o usuário não será criado. Revise o payload abaixo.'
    $userParams | ConvertTo-Json -Depth 6
    [pscustomobject]@{
        RequestId          = $RequestId
        ManagerDisplayName = $manager.DisplayName
        ManagerMail        = $manager.Mail
    }
    return
}

if ($PSCmdlet.ShouldProcess($UserPrincipalName, "Criar usuário cloud-only e atribuir gestor para o chamado $RequestId")) {
    $temporaryPassword = New-RandomTemporaryPassword
    $userParams.passwordProfile.password = $temporaryPassword
    $createdUser = $null

    try {
        $createdUser = New-MgUser -BodyParameter $userParams

        $managerReference = @{
            '@odata.id' = "https://graph.microsoft.com/v1.0/users/$($manager.Id)"
        }
        Set-MgUserManagerByRef `
            -UserId $createdUser.Id `
            -BodyParameter $managerReference
    }
    catch {
        if ($createdUser) {
            Write-Warning "A conta do chamado '$RequestId' foi criada com o ID '$($createdUser.Id)', mas a configuração não terminou. Revise-a antes de repetir o script."
        }
        throw
    }
    finally {
        $temporaryPassword = $null
    }

    Get-MgUser -UserId $createdUser.Id `
        -Property Id,DisplayName,UserPrincipalName,JobTitle,Department,EmployeeHireDate,UsageLocation |
        Select-Object @{ Name = 'RequestId'; Expression = { $RequestId } },Id,DisplayName,UserPrincipalName,JobTitle,Department,EmployeeHireDate,UsageLocation
}
