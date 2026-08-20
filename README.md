# Automatizando o ciclo de vida JML e PIM com Entra ID Governance

Laboratório didático para implementar governança de identidades no Microsoft 365 com recursos nativos do Microsoft Entra ID Governance e Microsoft Graph PowerShell.

O cenário acompanha a jornada Joiner, Mover e Leaver de uma colaboradora fictícia e cobre:

- onboarding orientado por `employeeHireDate` com Temporary Access Pass;
- pacote de acesso para Teams, SharePoint e aplicativo corporativo;
- aprovação pelo gestor;
- elegibilidade e ativação Just-In-Time com Privileged Identity Management;
- revisão trimestral das atribuições do pacote;
- offboarding orientado por `employeeLeaveDateTime`.

O artigo correspondente está disponível no [RookieOps](https://rookieops.dev/posts/governanca-identidades-m365-entra-id/).

## Segurança por padrão

- Nenhum script contém tenant, segredo, senha ou identificador real.
- Os scripts de alteração permanecem em simulação até que `-Apply` seja informado.
- Os workflows são criados com agenda desativada, salvo quando `-EnableSchedule` também é informado.
- `-WhatIf` continua disponível nas operações protegidas por `ShouldProcess`.
- A revisão trimestral usa `keepAccess` por padrão quando ninguém responde.
- Nenhum script foi executado contra um tenant real durante a criação deste laboratório.
- Use identidades descartáveis, um departamento piloto e contas de emergência fora do escopo.

### Anonimização

Os scripts não armazenam nomes de pessoas, emails, domínios, IDs de tenant, IDs de usuários, IDs de grupos, URLs de sites, segredos ou credenciais. Todos os valores contextuais são parâmetros obrigatórios ou opções escolhidas na execução.

Os únicos GUIDs fixos são identificadores públicos de definições de tarefas nativas do Lifecycle Workflows. As únicas URLs fixas são endpoints oficiais de `graph.microsoft.com`. Eles não identificam o ambiente de quem criou o laboratório.

> [!CAUTION]
> Revise IDs, escopos, filtros, aprovadores e efeitos de remoção antes de aplicar qualquer exemplo. Bloqueio de conta, revogação de sessões e remoção automática de acesso podem interromper serviços legítimos.

## Pré-requisitos

Instale os módulos primeiro. Antes de executar qualquer comando `Get-Mg*`, siga a seção [Clonar e conectar](#clonar-e-conectar) e abra uma sessão de leitura.

### Licenciamento

Para reproduzir todo o cenário, use Microsoft Entra ID Governance ou Microsoft Entra Suite para a população abrangida. Algumas capacidades de Entitlement Management, PIM e Access Reviews também estão disponíveis com Microsoft Entra ID P2, mas Lifecycle Workflows não está incluído em P2 isoladamente.

Valide os direitos do contrato da organização. A contagem pode abranger pessoas que recebem, solicitam, aprovam ou revisam acesso, conforme o recurso.

```powershell
Get-MgSubscribedSku |
  Select-Object SkuPartNumber, ConsumedUnits
```

### Funções e escopos

| Operação | Função administrativa indicada | Escopo delegado |
| --- | --- | --- |
| Criar e executar workflows | Lifecycle Workflows Administrator | `LifecycleWorkflows.ReadWrite.All` |
| Criar catálogo e adicionar recursos | Identity Governance Administrator ou Catalog owner | `EntitlementManagement.ReadWrite.All` |
| Criar pacote com recursos existentes | Access Package Manager ou função superior no catálogo | `EntitlementManagement.ReadWrite.All` |
| Configurar política e elegibilidade PIM | Privileged Role Administrator | `RoleEligibilitySchedule.ReadWrite.Directory` |
| Ativar uma função elegível | A própria pessoa elegível | `RoleAssignmentSchedule.ReadWrite.Directory` |
| Consultar objetos do laboratório | Leitor adequado ao objeto | `User.Read.All`, `Group.Read.All` e `Application.Read.All` |
| Consultar licenças | Directory Reader ou equivalente | `Organization.Read.All` |

Escopo OAuth e função administrativa são controles diferentes. A conta precisa de ambos. Evite Global Administrator quando uma função mais restrita for suficiente.

### PowerShell e módulos

PowerShell 7 é recomendado. Windows PowerShell 5.1 também é aceito pelo Microsoft Graph PowerShell SDK.

```powershell
$PSVersionTable.PSVersion
Install-Module Microsoft.Graph -Scope CurrentUser

Get-InstalledModule Microsoft.Graph* |
  Sort-Object Name |
  Select-Object Name, Version
```

Os scripts importam `Microsoft.Graph.Authentication` e `Microsoft.Graph.Identity.Governance`. Os comandos de descoberta usam também os módulos de usuários, grupos e aplicações instalados pelo metapacote `Microsoft.Graph`.

## Preparar o tenant piloto

### Identidade de Ana

Lifecycle Workflows não cria a conta. Um processo autorizado de RH, provisionamento ou administração deve criar Ana e preencher:

| Propriedade | Exemplo | Uso |
| --- | --- | --- |
| `department` | `Operações` | Escopo dos workflows |
| `employeeHireDate` | `2026-09-01T12:00:00Z` | Gatilho de entrada |
| `employeeLeaveDateTime` | `2026-12-18T22:00:00Z` | Gatilho de saída |
| `manager` | Gestor de Ana | TAP, aprovação e revisão |
| `mail` do gestor | Endereço válido | Notificações |
| `usageLocation` | `BR` | Atribuição de licenças |

Use UTC nos campos de data. Em produção, altere os dados na fonte autoritativa. Para usuários sincronizados, valide o mapeamento no Microsoft Entra Connect ou Cloud Sync.

```powershell
$ana = Get-MgUser -UserId '<USER_PRINCIPAL_NAME>' `
  -Property Id,DisplayName,Department,EmployeeHireDate,EmployeeLeaveDateTime,Mail,UsageLocation

$ana | Format-List
Get-MgUserManager -UserId $ana.Id | Format-List Id,AdditionalProperties
```

### Temporary Access Pass

No centro de administração do Microsoft Entra:

1. Abra **Entra ID > Authentication methods > Policies > Temporary Access Pass**.
2. Habilite o método para o grupo piloto.
3. Permita duração de 480 minutos, valor usado no workflow.
4. Verifique a compatibilidade com TAP de uso único.
5. Exclua contas de emergência.

A identidade de teste deve ser nova e não possuir métodos de autenticação, sessões anteriores ou funções administrativas.

### Recursos do Mover e do PIM

Prepare:

- catálogo `Operações`;
- grupo do Microsoft 365 associado ao Teams;
- site do SharePoint;
- aplicativo corporativo integrado ao Microsoft Entra ID;
- função de aplicativo, como `Default Access`;
- gestor de Ana;
- aprovador e revisor de fallback;
- dois aprovadores para ativações PIM.

O Access Package Manager usa recursos já presentes no catálogo. Para adicionar recursos, use Catalog owner ou Identity Governance Administrator.

## Clonar e conectar

```powershell
git clone https://github.com/tkusal/-Automatizando-o-ciclo-de-vida-JML-e-PIM-com-Entra-ID-Governance.git iam-governance-lab
Set-Location iam-governance-lab

# Somente leitura e descoberta
.\scripts\00-connect-graph.ps1

# Escrita, escolha apenas o perfil necessário
.\scripts\00-connect-graph.ps1 -WriteProfile Lifecycle
```

Os perfis de escrita são `Lifecycle`, `Entitlement`, `PimEligibility`, `PimActivation` e `All`. Evite `All` no uso cotidiano. Use `-TenantId '<TENANT_ID>'` quando a conta tiver acesso a mais de um tenant. Confirme sempre:

```powershell
Get-MgContext |
  Select-Object Account, TenantId, AuthType, Scopes
```

| Parâmetro de conexão | Padrão ou finalidade |
| --- | --- |
| `TenantId` | Seleciona explicitamente o tenant |
| `WriteProfile` | `None`, somente leitura e descoberta |

## Localizar os identificadores

Não use IDs copiados de exemplos. Consulte os objetos do tenant.

```powershell
Get-MgEntitlementManagementCatalog -All |
  Select-Object DisplayName, Id

Get-MgGroup -Filter "displayName eq 'Operações | Teams'" |
  Select-Object DisplayName, Id, GroupTypes

Get-MgServicePrincipal -Filter "displayName eq 'Aplicativo Operações'" |
  Select-Object DisplayName, Id, AppId

Get-MgUser -UserId 'aprovador@contoso.com' |
  Select-Object DisplayName, Id, UserPrincipalName
```

Use o `Id` do service principal em `ApplicationServicePrincipalId`, não o `AppId` do registro de aplicativo. Para SharePoint, informe a URL do site sem página ou biblioteca no final.

## Modos de execução

Todos os scripts de alteração seguem a mesma progressão:

1. Sem `-Apply`: consulta o necessário e imprime o payload.
2. Com `-Apply -WhatIf`: percorre as proteções e mostra os alvos.
3. Com `-Apply`: executa a mudança.
4. Com `-Apply -EnableSchedule`: cria um workflow com agenda ativa, somente após o teste sob demanda.

`DryRun` é o comportamento padrão, não um parâmetro separado.

## 1. Criar o Joiner

```powershell
# Conexão com o perfil mínimo
.\scripts\00-connect-graph.ps1 -WriteProfile Lifecycle

# DryRun
.\scripts\10-new-joiner-workflow.ps1 -Department 'Operações'

# WhatIf
.\scripts\10-new-joiner-workflow.ps1 `
  -Department 'Operações' `
  -Apply `
  -WhatIf

# Aplicação com agenda desligada
.\scripts\10-new-joiner-workflow.ps1 `
  -Department 'Operações' `
  -Apply
```

| Parâmetro | Obrigatório | Efeito |
| --- | --- | --- |
| `Department` | Sim | Forma o nome e o filtro do workflow |
| `EnableSchedule` | Não | Ativa a avaliação agendada |
| `Apply` | Não | Autoriza a criação |

No portal, abra **ID Governance > Lifecycle workflows > Workflows**, selecione o workflow e use **Run on demand** para Ana. A execução sob demanda ignora filtro e data. Aguarde `Completed` em **Workflow history** e confirme o TAP com o gestor.

Para reverter, desligue a agenda, exclua o workflow piloto e remova o TAP de Ana em **Authentication methods**.

## 2. Criar o pacote de acesso

```powershell
.\scripts\00-connect-graph.ps1 -WriteProfile Entitlement

.\scripts\20-new-access-package.ps1 `
  -CatalogId '<CATALOG_ID>' `
  -GroupId '<TEAM_GROUP_ID>' `
  -ApplicationServicePrincipalId '<SERVICE_PRINCIPAL_ID>' `
  -SharePointSiteUrl '<SHAREPOINT_SITE_URL>' `
  -FallbackApproverUserId '<APPROVER_USER_ID>' `
  -AccessPackageName '<ACCESS_PACKAGE_NAME>' `
  -ApplicationRoleName '<APPLICATION_ROLE_NAME>'
```

| Parâmetro | Obrigatório | Padrão ou finalidade |
| --- | --- | --- |
| `CatalogId` | Sim | Catálogo que receberá o pacote |
| `GroupId` | Sim | Grupo do Teams, função `Member` |
| `ApplicationServicePrincipalId` | Sim | Objeto corporativo do aplicativo |
| `SharePointSiteUrl` | Sim | Site do SharePoint, função `Member` |
| `FallbackApproverUserId` | Sim | Aprova quando `manager` não for localizado |
| `AccessPackageName` | Sim | Nome definido pela organização |
| `ApplicationRoleName` | Sim | Função exposta pelo aplicativo corporativo |
| `Apply` | Não | Autoriza recursos, pacote e política |

No portal, confirme que a política permite solicitação por membros, exige aprovação do gestor, usa o fallback, expira em 180 dias e exige justificativa. Teste no **My Access**. A execução aplicada retorna `AccessPackageId` e `AssignmentPolicyId`.

Para reverter, remova primeiro a atribuição de Ana. Depois oculte ou desabilite a política. Exclua pacote e recursos somente após conferir dependências.

## 3. Configurar PIM

Prepare a política no portal:

1. Abra **ID Governance > Privileged Identity Management > Microsoft Entra roles > Roles**.
2. Selecione **Exchange Administrator > Role settings > Edit**.
3. Defina duas horas como duração máxima.
4. Exija MFA, justificativa e, se aplicável, ticket.
5. Exija aprovação e selecione pelo menos dois aprovadores.
6. Revise notificações e salve.

Crie a elegibilidade com a sessão do Privileged Role Administrator:

```powershell
.\scripts\00-connect-graph.ps1 -WriteProfile PimEligibility

.\scripts\30-configure-pim-exchange.ps1 `
  -UserId '<USER_ID>' `
  -RoleDisplayName '<ROLE_DISPLAY_NAME>' `
  -CreateEligibility `
  -EligibilityDays 90 `
  -EligibilityJustification '<APPROVED_JUSTIFICATION>'
```

Depois desconecte e autentique como Ana para solicitar a ativação:

```powershell
Disconnect-MgGraph
.\scripts\00-connect-graph.ps1 -WriteProfile PimActivation

.\scripts\30-configure-pim-exchange.ps1 `
  -UserId '<USER_ID>' `
  -RoleDisplayName '<ROLE_DISPLAY_NAME>' `
  -Activate `
  -ActivationHours 2 `
  -Justification '<TICKET_AND_REASON>'
```

| Parâmetro | Obrigatório | Padrão ou finalidade |
| --- | --- | --- |
| `UserId` | Sim | ID da pessoa elegível |
| `RoleDisplayName` | Sim | Nome da função do Microsoft Entra |
| `CreateEligibility` | Uma ação | Cria elegibilidade administrativa |
| `Activate` | Uma ação | Solicita ativação pela própria pessoa |
| `EligibilityDays` | Não | 90 dias |
| `ActivationHours` | Não | 2 horas, máximo aceito pelo script: 8 |
| `EligibilityJustification` | Com `CreateEligibility` | Motivo aprovado para conceder elegibilidade |
| `Justification` | Com `Activate` | Chamado e motivo da ativação |
| `Apply` | Não | Autoriza a solicitação |

Valide os estados elegível, ativo e expirado, além dos logs e da aprovação. Para reverter, Ana desativa a função e o administrador remove a elegibilidade.

## 4. Habilitar a revisão trimestral

```powershell
.\scripts\00-connect-graph.ps1 -WriteProfile Entitlement

.\scripts\40-enable-quarterly-access-review.ps1 `
  -AssignmentPolicyId '<ASSIGNMENT_POLICY_ID>' `
  -AccessPackageId '<ACCESS_PACKAGE_ID>' `
  -FallbackReviewerUserId '<REVIEWER_USER_ID>' `
  -ReviewStartDate '2026-09-05'
```

| Parâmetro | Obrigatório | Padrão ou finalidade |
| --- | --- | --- |
| `AssignmentPolicyId` | Sim | Política que receberá `reviewSettings` |
| `AccessPackageId` | Sim | Pacote associado à política |
| `FallbackReviewerUserId` | Sim | Revisor quando o gestor não for encontrado |
| `ReviewStartDate` | Não | Sete dias após a execução |
| `ExpirationBehavior` | Não | `keepAccess` |
| `Apply` | Não | Autoriza a atualização completa da política |

Para remover acesso quando ninguém responder, informe `-ExpirationBehavior removeAccess`. Use isso somente após validar emails, gestores, fallback, prazo e rotina operacional.

Confirme ocorrência, notificação, decisão e justificativa em My Access. Para reverter, restaure a política anterior ou desabilite a revisão. Acesso já removido exige nova atribuição aprovada.

## 5. Criar o Leaver

Antes da saída, transfira propriedades, aplique retenção e inventarie acessos baseados em grupos. O script remove licenças diretas, não licenças herdadas por associação a grupos.

```powershell
.\scripts\00-connect-graph.ps1 -WriteProfile Lifecycle

.\scripts\50-new-leaver-workflow.ps1 -Department 'Operações'

.\scripts\50-new-leaver-workflow.ps1 `
  -Department 'Operações' `
  -Apply `
  -WhatIf
```

| Parâmetro | Obrigatório | Efeito |
| --- | --- | --- |
| `Department` | Sim | Forma o nome e o filtro do workflow |
| `EnableSchedule` | Não | Ativa a avaliação agendada |
| `Apply` | Não | Autoriza a criação |

O workflow ordena bloqueio da conta, revogação de tokens e remoção de licenças diretas. Teste sob demanda com uma identidade descartável. Confirme `accountEnabled = false`, logs de revogação e licenças removidas.

Se atingir a pessoa errada, desligue a agenda, reative a conta e restaure licenças e associações a partir do inventário. A revogação de sessões não pode ser desfeita. Para identidades sincronizadas, corrija também a fonte autoritativa.

## Critérios de aceite

| Etapa | Evidência mínima |
| --- | --- |
| Joiner | Histórico concluído e TAP entregue ao gestor |
| Pacote | Solicitação, aprovação, expiração e três recursos atribuídos |
| PIM | Elegibilidade sem privilégio permanente e ativação expirada |
| Revisão | Gestor, fallback, recorrência, decisão e justificativa registrados |
| Leaver | Conta bloqueada, revogação registrada e licenças diretas removidas |
| Reversão | Procedimento ensaiado com identidade descartável |

## Validar a sintaxe localmente

O comando abaixo analisa todos os scripts sem executá-los:

```powershell
Get-ChildItem .\scripts\*.ps1 | ForEach-Object {
  $tokens = $null
  $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile(
    $_.FullName,
    [ref]$tokens,
    [ref]$errors
  )

  if ($errors.Count -gt 0) {
    $errors
  } else {
    "OK: $($_.Name)"
  }
}
```

## Limitações intencionais

- Os exemplos não integram Workday, SAP ou outra fonte de RH.
- A política PIM é configurada no portal, pois o script modela elegibilidade e ativação.
- A remoção de licenças do Leaver afeta atribuições diretas.
- A revogação de tokens reduz a janela de uso, mas aplicativos específicos podem não reagir imediatamente.
- O laboratório não transfere propriedade de Teams, SharePoint, caixas postais ou recursos do Azure.
- Nenhum script executa automaticamente a reversão, pois ela depende do inventário e das aprovações da organização.

## Referências oficiais

- [Planejar Lifecycle Workflows](https://learn.microsoft.com/en-us/entra/id-governance/lifecycle-workflows-deployment)
- [Executar workflow sob demanda](https://learn.microsoft.com/en-us/entra/id-governance/on-demand-workflow)
- [Configurar Temporary Access Pass](https://learn.microsoft.com/en-us/entra/identity/authentication/howto-authentication-temporary-access-pass)
- [Criar um pacote de acesso](https://learn.microsoft.com/en-us/entra/id-governance/entitlement-management-access-package-create)
- [Configurar políticas do PIM](https://learn.microsoft.com/en-us/entra/id-governance/privileged-identity-management/pim-how-to-change-default-settings)
- [Criar revisões de pacote](https://learn.microsoft.com/en-us/entra/id-governance/entitlement-management-access-reviews-create)
- [Fundamentos de licenciamento](https://learn.microsoft.com/en-us/entra/id-governance/licensing-fundamentals)

## Licença

Este projeto é distribuído sob a [licença MIT](LICENSE).
