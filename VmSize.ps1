<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Azure VM Oversized Report - TEST</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
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
        .chart-container {
            background-color: #fff;
            padding: 20px;
            border-radius: 5px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            margin-bottom: 20px;
            max-height: 500px;
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
        .warning-high {
            background-color: #ffebee !important;
        }
        .warning-medium {
            background-color: #fff3e0 !important;
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
    <h1>Azure VM Oversized Report - TEST DATA</h1>

    <div class="summary">
        <h2>Executive Summary</h2>
        <div class="stat-box">
            <div class="stat-number">3</div>
            <div class="stat-label">Oversized VMs</div>
        </div>
    </div>

    <div class="chart-container">
        <h2>Time Above Threshold Analysis</h2>
        <canvas id="thresholdChart"></canvas>
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
                <th>CPU Peaks</th>
                <th>Avg Peak Duration (min)</th>
                <th>Time Above 80% (%)</th>
                <th>Avg Memory Usage (%)</th>
                <th>Memory Peaks</th>
                <th>Avg Peak Duration (min)</th>
                <th>Time Above 85% (%)</th>
            </tr>
        </thead>
        <tbody>            <tr class="">
                <td>Test-Subscription-1</td>
                <td>RG-TEST-PROD</td>
                <td>vm-test-web-01</td>
                <td>eastus</td>
                <td>Standard_D4s_v3</td>
                <td>4</td>
                <td>16</td>
                <td>12.5</td>
                <td>3</td>
                <td>15.5</td>
                <td>8.3</td>
                <td>18.7</td>
                <td>2</td>
                <td>10</td>
                <td>5.2</td>
            </tr>            <tr class="">
                <td>Test-Subscription-1</td>
                <td>RG-TEST-DEV</td>
                <td>vm-test-app-02</td>
                <td>westeurope</td>
                <td>Standard_D8s_v3</td>
                <td>8</td>
                <td>32</td>
                <td>8.2</td>
                <td>0</td>
                <td>0</td>
                <td>0</td>
                <td>22.3</td>
                <td>1</td>
                <td>25</td>
                <td>12.1</td>
            </tr>            <tr class="warning-medium">
                <td>Test-Subscription-2</td>
                <td>RG-DEMO</td>
                <td>vm-demo-db-01</td>
                <td>northeurope</td>
                <td>Standard_E4s_v3</td>
                <td>4</td>
                <td>32</td>
                <td>15.8</td>
                <td>5</td>
                <td>45.2</td>
                <td>25.7</td>
                <td>N/A</td>
                <td>0</td>
                <td>N/A</td>
                <td>N/A</td>
            </tr>        </tbody>
    </table>

    <div class="footer">
        <p>Report generated on 2025-11-05 17:08:38</p>
        <p>This is TEST DATA - Analysis period: 30 days | Thresholds: CPU < 20%, RAM < 30%</p>
    </div>

    <script>
        const ctx = document.getElementById('thresholdChart').getContext('2d');
        const chart = new Chart(ctx, {
            type: 'bar',
            data: {
                labels: ['0-10%', '10-20%', '20-30%', '30-50%', '50%+'],
                datasets: [{
                    label: 'CPU Time Above 80%',
                    data: [2, 0, 1, 0, 0],
                    backgroundColor: 'rgba(255, 99, 132, 0.7)',
                    borderColor: 'rgba(255, 99, 132, 1)',
                    borderWidth: 1
                }, {
                    label: 'Memory Time Above 85%',
                    data: [2, 1, 0, 0, 0],
                    backgroundColor: 'rgba(54, 162, 235, 0.7)',
                    borderColor: 'rgba(54, 162, 235, 1)',
                    borderWidth: 1
                }]
            },
            options: {
                responsive: true,
                maintainAspectRatio: true,
                scales: {
                    y: {
                        beginAtZero: true,
                        ticks: {
                            stepSize: 1
                        },
                        title: {
                            display: true,
                            text: 'Number of VMs'
                        }
                    },
                    x: {
                        title: {
                            display: true,
                            text: 'Time Above Threshold Range'
                        }
                    }
                },
                plugins: {
                    legend: {
                        display: true,
                        position: 'top'
                    },
                    tooltip: {
                        callbacks: {
                            label: function(context) {
                                return context.dataset.label + ': ' + context.parsed.y + ' VMs';
                            }
                        }
                    }
                }
            }
        });
    </script>
</body>
</html>
