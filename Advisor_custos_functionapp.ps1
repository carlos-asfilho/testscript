# Input bindings are passed in via param block.
param($Timer)

# Set TLS protocol to avoid SSL errors
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Get the current universal time in the default string format
$currentUTCtime = (Get-Date).ToUniversalTime()

# The 'IsPastDue' property is 'true' when the current function invocation is later than scheduled.
if ($Timer.IsPastDue) {
    Write-Output "PowerShell timer is running late!"
}

$results = @()

# Define tenant ID and subscription IDs
$tenantId = "bfafaa9a-8851-4ef8-855b-0e9c58eed2fe"
$SubscriptionIds = @(
    "6d539e62-773e-42fc-aa49-55c7bdef7b7b"
    "7cb91dce-a39e-4b52-9e4f-2481e21e25a0"
    "4d67eb4e-013f-4b6c-8677-6ef8649bcca1"
    "3cfc6eb2-277c-4936-b48d-60d77abc9c1e"
    "8066df73-6414-4681-859e-eeae80e51581"
    "3276bda1-f68f-4013-aff1-6b2be2bfc8ef"
    "7910d8a7-0128-42dc-868b-7f855e83a669"
    "9750d45b-4087-4414-9fa6-d90bdc958b4a"
    "119b91b5-7d53-4251-a8a0-aefe0def6c90"
    "93a66245-c573-449e-b083-fbfb9ef37832"
    "a10d5d8a-f80c-4682-af49-8114e2c6ad31"
)

foreach ($subId in $SubscriptionIds) {
    try {
        Set-AzContext -SubscriptionId $subId -TenantId $tenantId
        Write-Output "Processando subscription: $subId"

        # Example: Get subscription name
        $subname = Get-AzSubscription -SubscriptionId $subId
        Write-Output "Subscription name: $($subname.Name)"

        $Query = @"
        AdvisorResources
        | where type == "microsoft.advisor/recommendations"
        | where properties.category == "Cost"
        | extend resources = tostring(properties.resourceMetadata.resourceId),
                 savingsmonthly = todouble(properties.extendedProperties.savingsAmount),
                 annualSavings = todouble(properties.extendedProperties.annualSavingsAmount),
                 currency = tostring(properties.extendedProperties.savingsCurrency),
                 displaySKU = tostring(properties.extendedProperties.displaySKU),
                 subID = tostring(properties.extendedProperties.subId),
                 location = tostring(properties.extendedProperties.region),
                 solution = tostring(properties.shortDescription.solution)
        | summarize dcount(resources), bin(sum(savingsmonthly), 0.01), bin(sum(annualSavings), 0.01) by solution, currency, displaySKU, subID, location
        | project solution, displaySKU, subID, location, dcount_resources, sum_savingsmonthly, sum_annualSavings, currency
        | order by sum_annualSavings desc
"@

        $Costs = Search-AzGraph -Query $Query
        foreach ($row in $Costs) {
            $results += [pscustomobject]@{
                Solution         = $row.solution
                DisplaySKU       = $row.displaySKU
                SubscriptionID   = $row.subID
                Location         = $row.location
                ResourceCount    = $row.dcount_resources
                SavingsMonthly   = $row.sum_savingsmonthly
                AnnualSavings    = $row.sum_annualSavings
                Currency         = $row.currency
            }
        }
    } catch {
        Write-Output "Falha ao processar subscription $subId"
    }
}

# Get environment variable
$StorageAccount = "dxca10d5st4runbooks"
$Container = "dxcreports"
$SasToken = "sp=racwdl&st=2025-09-30T11:47:49Z&se=2029-01-01T20:02:49Z&spr=https&sv=2024-11-04&sr=c&sig=EcZqNEgnhw+w5dSrLrcvZ0XxFGclYYeI7/bohV+fieU="
$TenantName = "Nadro, S.A.P.I. de C.V."
$Subscription = Get-AzSubscription -SubscriptionId (Get-AzContext).Subscription
$SubscriptionID = $Subscription.Id
$SubscriptionName = $Subscription.Name -replace '[^\w\s\[\]/\\:*?<>|()&#\-_]', ''

$Formatteddate = (Get-date).ToUniversalTime().ToString("dd-MM-yyyy")
$parent = [System.IO.Path]::GetTempPath()
$Prefix = "Advisor/"
$FileName = "$Prefix" + "Advisor_Costs-$Formatteddate.csv"
$File = [String]::Concat($parent,$FileName)
$CurrentDate = Get-Date -Hour 0 -Minute 0 -Second 0
$MonthAgo = $CurrentDate.AddMonths(-1)
$StartDate = Get-Date $MonthAgo -Day 1
$EndDate = Get-Date $StartDate.AddMonths(1).AddSeconds(-1)
$From = Get-date $StartDate -Format 'yyyy-MM-dd'
$To = Get-date $EndDate -Format 'yyyy-MM-dd'
$results | Export-Csv -Path $File -NoTypeInformation -Encoding UTF8
Write-Output "Costs report saved to $File"

If(Test-path $File) {
    Write-Output "Exporting Results to CSV file: $File"  
    
    $storageObj = Get-AzStorageAccount | Where-Object {$_.StorageAccountName -eq $StorageAccount}
    $StorageContext = New-AzStorageContext -StorageAccountName $StorageAccount -SasToken "sp=racwdl&st=2025-09-30T11:47:49Z&se=2029-01-01T20:02:49Z&spr=https&sv=2024-11-04&sr=c&sig=EcZqNEgnhw%2Bw5dSrLrcvZ0XxFGclYYeI7%2FbohV%2BfieU%3D"
    $uploadfile = Set-AzStorageBlobContent -File $File -Container $Container -Blob $FileName -BlobType "Block" -Context $StorageContext -Force -Confirm:$false -AsJob
    
    do {
        Start-Sleep 1
    } until ($uploadfile.State -eq "Completed")
    
    Write-Output "Uploaded the Costs details to the storage account $StorageAccount under the container $Container."
    Write-Output "Job state: $($uploadfile.State)"

    #Define the number of days for file retention
    $monthsToRetain = 3

    # Get the current date and calculate the date threshold
    $dateThreshold = $currentDate.AddMonths(-$monthsToRetain)
	
    $allBlob = Get-AzStorageBlob -Container $Container -Context $StorageContext
        
    If($allBlob) {
        foreach ($Blob in $allBlob) {
	$lastModified = $Blob.LastModified
            if ($lastModified -lt $dateThreshold){
            Remove-AzStorageBlob -Container $Container -Blob $Blob.Name -Context $StorageContext -Force -Confirm:$false 
            Write-Output "Removing file $($Blob.Name) from Storage account..."
            }
        }
    }
    
    Remove-Item -Path $File -Force
}
Else {
    Write-Output "Error in exporting backup item data."
}