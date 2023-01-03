param(
  [Parameter(mandatory = $false)]
  [switch]$DryRun = $true,

  [Parameter(mandatory = $false)]
  [string]$ConnectionAssetName = "Automation-Hub-northeu",

  [Parameter(mandatory = $false)]
  [string]$ResourceGroupName,

  [Parameter(mandatory = $false)]
  [string]$TenantId = "10868dd3-36ce-4e6e-bf97-527004171368",

  [Parameter(mandatory = $false)]
  [switch]$TagResources = $true,

  [Parameter(mandatory = $false)]
  [string]$TagName = "Delete",

  [Parameter(mandatory = $false)]
  [string]$TagValue = "yes"
)

# Debug info
Write-Output "Running with parameters: DryRun = $DryRun, ConnectionAssetName = $ConnectionAssetName, TenantId = $TenantId, ResourceGroupName = $ResourceGroupName"

# Ensures you do not inherit an AzContext in your runbook
Disable-AzContextAutosave -Scope Process

# Connect to Azure with system-assigned managed identity
$AzureContext = (Connect-AzAccount -Identity).context

# set and store context
$AzureContext = Set-AzContext -SubscriptionName $AzureContext.Subscription -DefaultProfile $AzureContext

$SubscriptionId = $(Get-AzContext).Subscription.Id

# Function that sends a query to AzGraph and optionally deletes returned resources
# Parameters:
# - $Query: query to be sent
# - $ObjectName: modifies log output. Could be dynamically retrieved from the resource
# - $DryRun: if $true no resources are deleted, only marked with Azure Tags
function Inspect-Resources {
    param(
        [string]$Query,
        [string]$ObjectName,
        [string]$DryRun
    )
    # If a ResourceGroup has been specified, the query is scoped to that RG
    if ($ResourceGroupName) {
        $Query = $Query + " | where resourceGroup == '$ResourceGroupName'"
    }
    # Send query
    $Resources = Search-AzGraph $Query
    # Process query results
    if ($Resources) {
        foreach ($Resource in $Resources) {
            # If not dry run, delete resouce (NOT RECOMMENDED)
            if (!$DryRun) {
                Write-Output "$ObjectName $($Resource.name) in resource group $($Resource.resourceGroup) seems to be orphan, deleting it..."
                Remove-AzResource -ResourceId $Resource.Id -Force
            } else {
                # If running in Dry Run mode, it will only show a message and mark the resource with a tag
                if ($TagResources) {
                    Write-Output "$ObjectName $($Resource.name) in resource group $($Resource.resourceGroup) seems to be orphan, tagging as $($TagName)/$($TagValue)"
                    $Tags = (Get-AzResource -ResourceId $Resource.id).Tags
                    # Add or modify existing key
                    if ($Tags -ne $null -and $Tags.ContainsKey($TagName)) {
                        $Tags[$TagName] = $TagValue
                    } else {
                        $Tags += @{$TagName=$TagValue}
                    }
                    New-AzTag -ResourceId $Resource.id -Tag $Tags
                } else {
                    Write-Output "$ObjectName $($Resource.name) in resource group $($Resource.resourceGroup) seems to be orphan"
                }
            }
        }
    }
    else
    {
        # If the query returned an empty string
        if ($ResourceGroupName) {
            Write-Output "No orphan $($ObjectName)s found in resource group $ResourceGroupName"
        } else {
            Write-Output "No orphan $($ObjectName)s found in the subscription"
        }
    }

}

# Get orphan disks
$Query = "Resources | where subscriptionId=='$SubscriptionId' and type =~ 'microsoft.compute/disks' and managedBy ==''"
Inspect-Resources -Query $Query -ObjectName 'disk' -DryRun $DryRun

# Get orphan NSGs
$Query = "Resources | where subscriptionId=='$SubscriptionId' and type =~ 'microsoft.network/networksecuritygroups' and isnull(properties.networkInterfaces) and isnull(properties.subnets)"
Inspect-Resources -Query $Query -ObjectName 'NSG' -DryRun $DryRun

# Get orphan NICs
# To show aliases/properties for NICs:
# $(Search-AzGraph -Query "Resources | where type =~ 'Microsoft.Network/networkInterfaces' | limit 1 | project aliases").aliases
# $(Search-AzGraph -Query "Resources | where subscriptionId=='$SubscriptionId' and type =~ 'microsoft.network/networkinterfaces' | limit 1").properties
$Query = "Resources | where subscriptionId=='$SubscriptionId' and type =~ 'microsoft.network/networkinterfaces' and isnull(properties.virtualMachine)"
Inspect-Resources -Query $Query -ObjectName 'NIC' -DryRun $DryRun

# Public IPs
# To show aliases for public IPs:
# $(Search-AzGraph -Query "Resources | where type =~ 'Microsoft.Network/publicipaddresses' | limit 1 | project aliases").aliases
$Query = "Resources | where subscriptionId=='$SubscriptionId' and type =~ 'microsoft.network/publicipaddresses' and properties.ipConfiguration == '' and properties.natGateway == ''"
Inspect-Resources -Query $Query -ObjectName 'PIP' -DryRun $DryRun