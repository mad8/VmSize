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

# Fonction pour obtenir les métriques CPU
function Get-VMCPUMetrics {
    param(
        [string]$ResourceId,
        [datetime]$StartTime,
        [datetime]$EndTime
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

            return @{
                Average = [math]::Round($avgCPU, 2)
                Maximum = [math]::Round($maxCPU, 2)
            }
        }
    }
    catch {
        Write-ColorOutput "Erreur lors de la récupération des métriques CPU pour $ResourceId : $_" "Warning"
    }

    return @{
        Average = 0
        Maximum = 0
    }
}

# Fonction pour obtenir les métriques RAM
function Get-VMMemoryMetrics {
    param(
        [string]$ResourceId,
        [datetime]$StartTime,
        [datetime]$EndTime
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

            return @{
                AverageAvailableGB = [math]::Round($avgAvailableMemoryBytes / 1GB, 2)
                MinAvailableGB = [math]::Round($minAvailableMemoryBytes / 1GB, 2)
            }
        }
    }
    catch {
        # La métrique "Available Memory Bytes" nécessite l'agent de diagnostic
        # Si non disponible, on retourne des valeurs nulles
        return @{
            AverageAvailableGB = $null
            MinAvailableGB = $null
        }
    }

    return @{
        AverageAvailableGB = $null
        MinAvailableGB = $null
    }
}

# Fonction pour obtenir les informations de sizing d'une VM
function Get-VMSizeInfo {
    param([string]$VMSize)

    try {
        # Ceci est une approximation - pour des données exactes, vous devrez interroger Get-AzVMSize
        # avec le location de la VM
        $sizeInfo = @{
            "Standard_B1s" = @{Cores = 1; MemoryGB = 1}
            "Standard_B2s" = @{Cores = 2; MemoryGB = 4}
            "Standard_D2s_v3" = @{Cores = 2; MemoryGB = 8}
            "Standard_D4s_v3" = @{Cores = 4; MemoryGB = 16}
            "Standard_D8s_v3" = @{Cores = 8; MemoryGB = 32}
            "Standard_D16s_v3" = @{Cores = 16; MemoryGB = 64}
            "Standard_E2s_v3" = @{Cores = 2; MemoryGB = 16}
            "Standard_E4s_v3" = @{Cores = 4; MemoryGB = 32}
            "Standard_E8s_v3" = @{Cores = 8; MemoryGB = 64}
            "Standard_F2s_v2" = @{Cores = 2; MemoryGB = 4}
            "Standard_F4s_v2" = @{Cores = 4; MemoryGB = 8}
        }

        if ($sizeInfo.ContainsKey($VMSize)) {
            return $sizeInfo[$VMSize]
        }
    }
    catch {}

    # Valeurs par défaut si le type n'est pas reconnu
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

            # Obtenir les informations de sizing
            $vmSize = Get-VMSizeInfo -VMSize $vm.HardwareProfile.VmSize

            # Calculer l'utilisation mémoire en pourcentage
            $memoryUsagePercent = $null
            if ($null -ne $memMetrics.AverageAvailableGB -and $vmSize.MemoryGB -gt 0) {
                $avgUsedMemory = $vmSize.MemoryGB - $memMetrics.AverageAvailableGB
                $memoryUsagePercent = [math]::Round(($avgUsedMemory / $vmSize.MemoryGB) * 100, 2)
            }

            # Déterminer le statut de sizing basé sur les métriques historiques
            $sizingStatus = "OK"

            # Analyser uniquement si on a des données de métriques (Average > 0 signifie qu'il y a eu de l'activité)
            if ($cpuMetrics.Average -gt 0 -or ($null -ne $memoryUsagePercent -and $memoryUsagePercent -gt 0)) {
                # Analyse du CPU et RAM
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
                    AvgMemoryUsagePercent = $memoryUsagePercent
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
                <th>Memory Usage (%)</th>
            </tr>
        </thead>
        <tbody>
"@

        foreach ($item in $Data) {
            $memUsage = if ($null -ne $item.AvgMemoryUsagePercent) { $item.AvgMemoryUsagePercent } else { "N/A" }

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
                <td>$memUsage</td>
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
