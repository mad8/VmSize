<#
.SYNOPSIS
    Script pour analyser l'utilisation des ressources Azure VM (CPU et RAM) vs le sizing configuré.

.DESCRIPTION
    Ce script récupère les métriques d'utilisation des VMs Azure et les compare au sizing
    pour identifier les VMs oversized ou undersized.

.PARAMETER SubscriptionIds
    Liste des IDs de souscriptions Azure à analyser (séparés par des virgules).

.PARAMETER ResourceGroupName
    Nom d'un Resource Group spécifique à analyser (optionnel).

.PARAMETER DaysToAnalyze
    Nombre de jours d'historique à analyser (par défaut: 30 jours).

.PARAMETER OutputPath
    Chemin du fichier de sortie pour le rapport (par défaut: rapport dans le répertoire courant).

.PARAMETER ExportFormat
    Format d'export: CSV, HTML, ou Both (par défaut: Both).

.EXAMPLE
    .\Get-AzureVMSizingReport.ps1 -SubscriptionIds "sub-id-1,sub-id-2" -DaysToAnalyze 30

.EXAMPLE
    .\Get-AzureVMSizingReport.ps1 -SubscriptionIds "sub-id-1" -ResourceGroupName "RG-PROD" -ExportFormat HTML

.NOTES
    Version: 1.0
    Auteur: Script généré pour l'analyse de sizing Azure VM
    Prérequis: Module Az.Accounts, Az.Compute, Az.Monitor
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionIds,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [int]$DaysToAnalyze = 30,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\AzureVMSizingReport",

    [Parameter(Mandatory = $false)]
    [ValidateSet("CSV", "HTML", "Both")]
    [string]$ExportFormat = "Both",

    [Parameter(Mandatory = $false)]
    [int]$CPUOversizedThreshold = 20,

    [Parameter(Mandatory = $false)]
    [int]$RAMOversizedThreshold = 30
)

#Requires -Modules Az.Accounts, Az.Compute, Az.Monitor

# Fonction pour écrire des messages colorés
function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$Type = "Info"
    )

    switch ($Type) {
        "Success" { Write-Host $Message -ForegroundColor Green }
        "Warning" { Write-Host $Message -ForegroundColor Yellow }
        "Error" { Write-Host $Message -ForegroundColor Red }
        "Info" { Write-Host $Message -ForegroundColor Cyan }
        default { Write-Host $Message }
    }
}

# Fonction pour vérifier et installer les modules requis
function Test-AzModules {
    Write-ColorOutput "Vérification des modules Azure PowerShell..." "Info"

    $requiredModules = @("Az.Accounts", "Az.Compute", "Az.Monitor")
    $missingModules = @()

    foreach ($module in $requiredModules) {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            $missingModules += $module
        }
    }

    if ($missingModules.Count -gt 0) {
        Write-ColorOutput "Modules manquants: $($missingModules -join ', ')" "Warning"
        Write-ColorOutput "Installez-les avec: Install-Module -Name Az -AllowClobber -Scope CurrentUser" "Warning"
        return $false
    }

    Write-ColorOutput "Tous les modules requis sont installés." "Success"
    return $true
}

# Fonction pour se connecter à Azure
function Connect-AzureAccount {
    Write-ColorOutput "Connexion à Azure..." "Info"

    try {
        # Vérifier si déjà connecté
        $context = Get-AzContext -ErrorAction SilentlyContinue

        if ($null -eq $context) {
            Write-ColorOutput "Aucune session Azure active. Ouverture de la fenêtre d'authentification..." "Warning"
            Connect-AzAccount -ErrorAction Stop | Out-Null
            $context = Get-AzContext
        }

        Write-ColorOutput "Connecté en tant que: $($context.Account.Id)" "Success"
        return $true
    }
    catch {
        Write-ColorOutput "Erreur lors de la connexion à Azure: $_" "Error"
        return $false
    }
}

# Fonction pour obtenir les métriques CPU avec analyse des pics soutenus
function Get-VMCPUMetrics {
    param(
        [string]$ResourceId,
        [datetime]$StartTime,
        [datetime]$EndTime,
        [int]$HighCPUThreshold = 80
    )

    try {
        $metrics = Get-AzMetric -ResourceId $ResourceId `
            -MetricName "Percentage CPU" `
            -StartTime $StartTime `
            -EndTime $EndTime `
            -TimeGrain 01:00:00 `
            -AggregationType Average `
            -ErrorAction Stop

        if ($metrics.Data.Count -gt 0) {
            $avgCPU = ($metrics.Data | Measure-Object -Property Average -Average).Average
            $maxCPU = ($metrics.Data | Measure-Object -Property Average -Maximum).Maximum

            # Analyser les pics soutenus (CPU > seuil pendant plusieurs heures consécutives)
            $highCPUPeriods = @()
            $currentPeriodStart = $null
            $currentPeriodDuration = 0

            foreach ($dataPoint in $metrics.Data) {
                if ($dataPoint.Average -ge $HighCPUThreshold) {
                    if ($null -eq $currentPeriodStart) {
                        $currentPeriodStart = $dataPoint.TimeStamp
                    }
                    $currentPeriodDuration++
                } else {
                    if ($currentPeriodDuration -gt 0) {
                        $highCPUPeriods += $currentPeriodDuration
                        $currentPeriodStart = $null
                        $currentPeriodDuration = 0
                    }
                }
            }
            # Ajouter la dernière période si elle existe
            if ($currentPeriodDuration -gt 0) {
                $highCPUPeriods += $currentPeriodDuration
            }

            # Calculer la durée moyenne des pics
            $avgPeakDuration = if ($highCPUPeriods.Count -gt 0) {
                [math]::Round(($highCPUPeriods | Measure-Object -Average).Average, 1)
            } else {
                0
            }

            # Nombre de pics
            $peakCount = $highCPUPeriods.Count

            return @{
                Average = [math]::Round($avgCPU, 2)
                Maximum = [math]::Round($maxCPU, 2)
                PeakCount = $peakCount
                AvgPeakDurationHours = $avgPeakDuration
            }
        }
    }
    catch {
        Write-ColorOutput "Erreur lors de la récupération des métriques CPU pour $ResourceId : $_" "Warning"
    }

    return @{
        Average = 0
        Maximum = 0
        PeakCount = 0
        AvgPeakDurationHours = 0
    }
}

# Fonction pour obtenir les métriques RAM avec analyse des pics soutenus
function Get-VMMemoryMetrics {
    param(
        [string]$ResourceId,
        [datetime]$StartTime,
        [datetime]$EndTime,
        [int]$HighMemoryUsageThreshold = 85
    )

    try {
        $metrics = Get-AzMetric -ResourceId $ResourceId `
            -MetricName "Available Memory Bytes" `
            -StartTime $StartTime `
            -EndTime $EndTime `
            -TimeGrain 01:00:00 `
            -AggregationType Average `
            -ErrorAction Stop

        if ($metrics.Data.Count -gt 0) {
            $avgAvailableMemoryBytes = ($metrics.Data | Measure-Object -Property Average -Average).Average
            $minAvailableMemoryBytes = ($metrics.Data | Measure-Object -Property Average -Minimum).Minimum

            # Analyser les pics soutenus de mémoire (besoin de connaître la RAM totale pour calculer le %)
            # On stocke les données brutes et on fera le calcul plus tard avec la RAM totale
            $availableMemoryData = $metrics.Data | ForEach-Object {
                [math]::Round($_.Average / 1GB, 2)
            }

            return @{
                AverageAvailableGB = [math]::Round($avgAvailableMemoryBytes / 1GB, 2)
                MinAvailableGB = [math]::Round($minAvailableMemoryBytes / 1GB, 2)
                RawData = $metrics.Data
            }
        }
    }
    catch {
        # La métrique "Available Memory Bytes" nécessite l'agent de diagnostic
        # Si non disponible, on retourne des valeurs nulles
        return @{
            AverageAvailableGB = $null
            MinAvailableGB = $null
            RawData = $null
        }
    }

    return @{
        AverageAvailableGB = $null
        MinAvailableGB = $null
        RawData = $null
    }
}

# Fonction pour analyser les pics soutenus de mémoire
function Get-MemoryPeakAnalysis {
    param(
        [array]$RawData,
        [double]$TotalMemoryGB,
        [int]$HighMemoryUsageThreshold = 85
    )

    if ($null -eq $RawData -or $RawData.Count -eq 0 -or $TotalMemoryGB -le 0) {
        return @{
            PeakCount = 0
            AvgPeakDurationHours = 0
        }
    }

    $highMemoryPeriods = @()
    $currentPeriodDuration = 0

    foreach ($dataPoint in $RawData) {
        $availableGB = [math]::Round($dataPoint.Average / 1GB, 2)
        $usedPercent = (($TotalMemoryGB - $availableGB) / $TotalMemoryGB) * 100

        if ($usedPercent -ge $HighMemoryUsageThreshold) {
            $currentPeriodDuration++
        } else {
            if ($currentPeriodDuration -gt 0) {
                $highMemoryPeriods += $currentPeriodDuration
                $currentPeriodDuration = 0
            }
        }
    }
    # Ajouter la dernière période si elle existe
    if ($currentPeriodDuration -gt 0) {
        $highMemoryPeriods += $currentPeriodDuration
    }

    # Calculer la durée moyenne des pics
    $avgPeakDuration = if ($highMemoryPeriods.Count -gt 0) {
        [math]::Round(($highMemoryPeriods | Measure-Object -Average).Average, 1)
    } else {
        0
    }

    return @{
        PeakCount = $highMemoryPeriods.Count
        AvgPeakDurationHours = $avgPeakDuration
    }
}

# Fonction pour obtenir les informations de sizing d'une VM depuis Azure
function Get-VMSizeInfo {
    param(
        [string]$VMSize,
        [string]$Location
    )

    try {
        # Récupérer les informations réelles depuis Azure
        $vmSizes = Get-AzVMSize -Location $Location -ErrorAction Stop
        $sizeInfo = $vmSizes | Where-Object { $_.Name -eq $VMSize }

        if ($sizeInfo) {
            return @{
                Cores = $sizeInfo.NumberOfCores
                MemoryGB = [math]::Round($sizeInfo.MemoryInMB / 1024, 0)
            }
        }
    }
    catch {
        Write-ColorOutput "Erreur lors de la récupération des infos de sizing pour $VMSize : $_" "Warning"
    }

    # Valeurs par défaut si le type n'est pas trouvé
    return @{Cores = 0; MemoryGB = 0}
}

# Fonction principale pour analyser les VMs
function Get-VMAnalysis {
    $startTime = (Get-Date).AddDays(-$DaysToAnalyze)
    $endTime = Get-Date

    Write-ColorOutput "`nPériode d'analyse: du $($startTime.ToString('yyyy-MM-dd')) au $($endTime.ToString('yyyy-MM-dd'))" "Info"
    Write-ColorOutput "Seuils d'oversizing: CPU < $CPUOversizedThreshold%, RAM < $RAMOversizedThreshold%`n" "Info"

    $allResults = @()
    $subscriptions = @()

    # Déterminer les souscriptions à analyser
    if ($SubscriptionIds) {
        $subIds = $SubscriptionIds -split ','
        foreach ($subId in $subIds) {
            $sub = Get-AzSubscription -SubscriptionId $subId.Trim() -ErrorAction SilentlyContinue
            if ($sub) {
                $subscriptions += $sub
            }
            else {
                Write-ColorOutput "Souscription non trouvée: $subId" "Warning"
            }
        }
    }
    else {
        # Si aucune souscription spécifiée, utiliser toutes les souscriptions accessibles
        $subscriptions = Get-AzSubscription
    }

    if ($subscriptions.Count -eq 0) {
        Write-ColorOutput "Aucune souscription à analyser." "Error"
        return $allResults
    }

    Write-ColorOutput "Nombre de souscriptions à analyser: $($subscriptions.Count)" "Info"

    foreach ($subscription in $subscriptions) {
        Write-ColorOutput "`n=== Analyse de la souscription: $($subscription.Name) ===" "Info"
        Set-AzContext -SubscriptionId $subscription.Id | Out-Null

        # Récupérer les VMs
        $vms = @()
        if ($ResourceGroupName) {
            Write-ColorOutput "Récupération des VMs du Resource Group: $ResourceGroupName" "Info"
            $vms = Get-AzVM -ResourceGroupName $ResourceGroupName -Status -ErrorAction SilentlyContinue
        }
        else {
            Write-ColorOutput "Récupération de toutes les VMs de la souscription..." "Info"
            $vms = Get-AzVM -Status
        }

        Write-ColorOutput "Nombre de VMs trouvées: $($vms.Count)" "Info"

        $vmCounter = 0
        foreach ($vm in $vms) {
            $vmCounter++
            Write-ColorOutput "[$vmCounter/$($vms.Count)] Analyse de la VM: $($vm.Name)" "Info"

            # Obtenir le statut de la VM
            $powerState = ($vm.PowerState -split ' ')[1]

            # Récupérer les métriques historiques depuis Azure Monitor (indépendamment de l'état actuel)
            # Azure Monitor conserve l'historique même pour les VMs arrêtées
            $cpuMetrics = Get-VMCPUMetrics -ResourceId $vm.Id -StartTime $startTime -EndTime $endTime
            $memMetrics = Get-VMMemoryMetrics -ResourceId $vm.Id -StartTime $startTime -EndTime $endTime

            # Obtenir les informations de sizing réelles depuis Azure
            $vmSize = Get-VMSizeInfo -VMSize $vm.HardwareProfile.VmSize -Location $vm.Location

            # Calculer l'utilisation mémoire en pourcentage
            $memoryUsagePercent = $null
            if ($null -ne $memMetrics.AverageAvailableGB -and $vmSize.MemoryGB -gt 0) {
                $avgUsedMemory = $vmSize.MemoryGB - $memMetrics.AverageAvailableGB
                $memoryUsagePercent = [math]::Round(($avgUsedMemory / $vmSize.MemoryGB) * 100, 2)
            }

            # Analyser les pics soutenus de mémoire
            $memoryPeakAnalysis = Get-MemoryPeakAnalysis -RawData $memMetrics.RawData -TotalMemoryGB $vmSize.MemoryGB

            # Déterminer le statut de sizing basé sur les métriques historiques
            $sizingStatus = "OK"

            # Analyser uniquement si on a des données de métriques (Average > 0 signifie qu'il y a eu de l'activité)
            if ($cpuMetrics.Average -gt 0 -or ($null -ne $memoryUsagePercent -and $memoryUsagePercent -gt 0)) {
                # Analyser le CPU et RAM moyens pour déterminer si oversized
                if ($cpuMetrics.Average -lt $CPUOversizedThreshold -and
                    ($null -eq $memoryUsagePercent -or $memoryUsagePercent -lt $RAMOversizedThreshold)) {
                    $sizingStatus = "OVERSIZED"
                }
                elseif ($cpuMetrics.Average -lt $CPUOversizedThreshold) {
                    $sizingStatus = "CPU_OVERSIZED"
                }
                elseif ($null -ne $memoryUsagePercent -and $memoryUsagePercent -lt $RAMOversizedThreshold) {
                    $sizingStatus = "RAM_OVERSIZED"
                }
            }

            # Filtrer uniquement les VMs oversized (basé sur l'historique Azure Monitor)
            $isOversized = $sizingStatus -like "*OVERSIZED*"

            if ($isOversized) {
                $result = [PSCustomObject]@{
                    Subscription = $subscription.Name
                    SubscriptionId = $subscription.Id
                    ResourceGroup = $vm.ResourceGroupName
                    VMName = $vm.Name
                    Location = $vm.Location
                    VMSize = $vm.HardwareProfile.VmSize
                    Cores = $vmSize.Cores
                    MemoryGB = $vmSize.MemoryGB
                    PowerState = $powerState
                    AvgCPUPercent = $cpuMetrics.Average
                    MaxCPUPercent = $cpuMetrics.Maximum
                    CPUPeakCount = $cpuMetrics.PeakCount
                    CPUAvgPeakDurationHours = $cpuMetrics.AvgPeakDurationHours
                    AvgMemoryUsagePercent = $memoryUsagePercent
                    MemoryPeakCount = $memoryPeakAnalysis.PeakCount
                    MemoryAvgPeakDurationHours = $memoryPeakAnalysis.AvgPeakDurationHours
                    AvailableMemoryGB = $memMetrics.AverageAvailableGB
                    AnalysisPeriodDays = $DaysToAnalyze
                }

                $allResults += $result
            }
        }
    }

    return $allResults
}

# Fonction pour exporter en CSV
function Export-ToCSV {
    param([array]$Data, [string]$Path)

    try {
        $csvPath = "$Path.csv"
        $Data | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        Write-ColorOutput "CSV report generated: $csvPath" "Success"
    }
    catch {
        Write-ColorOutput "Error generating CSV: $_" "Error"
    }
}

# Fonction pour exporter en HTML
function Export-ToHTML {
    param([array]$Data, [string]$Path)

    try {
        $htmlPath = "$Path.html"

        # Statistiques globales
        $totalVMs = $Data.Count
        $avgCPU = if ($Data.Count -gt 0) {
            [math]::Round(($Data | Measure-Object -Property AvgCPUPercent -Average).Average, 2)
        } else {
            0
        }

        # Calculer la moyenne de RAM usage (exclure les valeurs nulles)
        $avgMemory = if ($Data.Count -gt 0) {
            $memoryData = $Data | Where-Object { $null -ne $_.AvgMemoryUsagePercent }
            if ($memoryData.Count -gt 0) {
                [math]::Round(($memoryData | Measure-Object -Property AvgMemoryUsagePercent -Average).Average, 2)
            } else {
                "N/A"
            }
        } else {
            "N/A"
        }

        $html = @"
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Azure VM Oversized Report</title>
    <style>
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            margin: 20px;
            background-color: #f5f5f5;
        }
        h1 {
            color: #0078d4;
            border-bottom: 3px solid #0078d4;
            padding-bottom: 10px;
        }
        h2 {
            color: #005a9e;
            margin-top: 30px;
        }
        .summary {
            background-color: #fff;
            padding: 20px;
            border-radius: 5px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            margin-bottom: 20px;
        }
        .stat-box {
            display: inline-block;
            background-color: #ff8c00;
            color: white;
            padding: 15px 25px;
            margin: 10px;
            border-radius: 5px;
            min-width: 150px;
            text-align: center;
        }
        .stat-number {
            font-size: 32px;
            font-weight: bold;
        }
        .stat-label {
            font-size: 14px;
            margin-top: 5px;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            background-color: #fff;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        th {
            background-color: #0078d4;
            color: white;
            padding: 12px;
            text-align: left;
            font-weight: bold;
        }
        td {
            padding: 10px;
            border-bottom: 1px solid #ddd;
        }
        tr:hover {
            background-color: #fffbf0;
        }
        .footer {
            margin-top: 30px;
            padding: 20px;
            background-color: #fff;
            border-radius: 5px;
            text-align: center;
            color: #605e5c;
        }
    </style>
</head>
<body>
    <h1>Azure VM Oversized Report</h1>

    <div class="summary">
        <h2>Executive Summary</h2>
        <div class="stat-box">
            <div class="stat-number">$totalVMs</div>
            <div class="stat-label">Oversized VMs</div>
        </div>
        <div class="stat-box">
            <div class="stat-number">$avgCPU%</div>
            <div class="stat-label">Average CPU Usage</div>
        </div>
        <div class="stat-box">
            <div class="stat-number">$avgMemory$(if ($avgMemory -ne 'N/A') { '%' })</div>
            <div class="stat-label">Average Memory Usage</div>
        </div>
    </div>

    <h2>Oversized VMs Details</h2>
    <table>
        <thead>
            <tr>
                <th>Subscription</th>
                <th>Resource Group</th>
                <th>VM Name</th>
                <th>Location</th>
                <th>VM Size</th>
                <th>vCores</th>
                <th>Memory (GB)</th>
                <th>Avg CPU (%)</th>
                <th>Max CPU (%)</th>
                <th>CPU Peaks</th>
                <th>Avg Peak Duration (h)</th>
                <th>Memory Usage (%)</th>
                <th>Memory Peaks</th>
                <th>Avg Peak Duration (h)</th>
            </tr>
        </thead>
        <tbody>
"@

        foreach ($item in $Data) {
            $memUsage = if ($null -ne $item.AvgMemoryUsagePercent) { $item.AvgMemoryUsagePercent } else { "N/A" }
            $memPeakCount = if ($null -ne $item.MemoryPeakCount) { $item.MemoryPeakCount } else { "N/A" }
            $memPeakDuration = if ($null -ne $item.MemoryAvgPeakDurationHours -and $item.MemoryAvgPeakDurationHours -gt 0) { $item.MemoryAvgPeakDurationHours } else { "N/A" }

            $html += @"
            <tr>
                <td>$($item.Subscription)</td>
                <td>$($item.ResourceGroup)</td>
                <td>$($item.VMName)</td>
                <td>$($item.Location)</td>
                <td>$($item.VMSize)</td>
                <td>$($item.Cores)</td>
                <td>$($item.MemoryGB)</td>
                <td>$($item.AvgCPUPercent)</td>
                <td>$($item.MaxCPUPercent)</td>
                <td>$($item.CPUPeakCount)</td>
                <td>$($item.CPUAvgPeakDurationHours)</td>
                <td>$memUsage</td>
                <td>$memPeakCount</td>
                <td>$memPeakDuration</td>
            </tr>
"@
        }

        $html += @"
        </tbody>
    </table>

    <div class="footer">
        <p>Report generated on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</p>
        <p>Analysis period: $DaysToAnalyze days | Thresholds: CPU < $CPUOversizedThreshold%, RAM < $RAMOversizedThreshold%</p>
    </div>
</body>
</html>
"@

        $html | Out-File -FilePath $htmlPath -Encoding UTF8
        Write-ColorOutput "HTML report generated: $htmlPath" "Success"
    }
    catch {
        Write-ColorOutput "Error generating HTML: $_" "Error"
    }
}

# =====================
# SCRIPT PRINCIPAL
# =====================

Write-ColorOutput "`n========================================" "Info"
Write-ColorOutput "  Azure VM Sizing Analysis Report" "Info"
Write-ColorOutput "========================================`n" "Info"

# Vérifier les modules
if (-not (Test-AzModules)) {
    Write-ColorOutput "`nScript interrompu: modules manquants." "Error"
    exit 1
}

# Connexion à Azure
if (-not (Connect-AzureAccount)) {
    Write-ColorOutput "`nScript interrompu: échec de connexion à Azure." "Error"
    exit 1
}

# Exécuter l'analyse
Write-ColorOutput "`n--- Début de l'analyse ---`n" "Info"
$results = Get-VMAnalysis

# Afficher un résumé
Write-ColorOutput "`n========================================" "Info"
Write-ColorOutput "  Analysis Summary" "Info"
Write-ColorOutput "========================================" "Info"
Write-ColorOutput "Oversized VMs found: $($results.Count)" "Warning"
if ($results.Count -gt 0) {
    $avgCPUAll = [math]::Round(($results | Measure-Object -Property AvgCPUPercent -Average).Average, 2)
    Write-ColorOutput "Average CPU usage: $avgCPUAll%" "Info"
}

# Exporter les résultats
if ($results.Count -gt 0) {
    Write-ColorOutput "`n--- Report Generation ---`n" "Info"
    Write-ColorOutput "Output path: $OutputPath" "Info"

    switch ($ExportFormat) {
        "CSV" {
            Export-ToCSV -Data $results -Path $OutputPath
        }
        "HTML" {
            Export-ToHTML -Data $results -Path $OutputPath
        }
        "Both" {
            Export-ToCSV -Data $results -Path $OutputPath
            Export-ToHTML -Data $results -Path $OutputPath
        }
    }

    Write-ColorOutput "`nReports generated successfully in: $(Split-Path -Parent $OutputPath)" "Success"
}
else {
    Write-ColorOutput "`nNo oversized VMs found. All VMs are properly sized!" "Success"
    Write-ColorOutput "No reports will be generated." "Info"
}

Write-ColorOutput "`n========================================" "Success"
Write-ColorOutput "  Analysis completed successfully!" "Success"
Write-ColorOutput "========================================`n" "Success"
