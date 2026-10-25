
param(
    [Parameter(Mandatory = $true)]
    [string]$Url,

    [int]$Retries = 10,

    [int]$DelaySeconds = 2
)

$ErrorActionPreference = "Stop"

for ($attempt = 1; $attempt -le $Retries; $attempt++) {
    try {
        $response = Invoke-RestMethod `
            -Uri $Url `
            -Method Get `
            -TimeoutSec 3

        if ($response.status -eq "healthy") {
            Write-Host "Health check passed: $Url"
            Write-Host "Application version: $($response.version)"
            exit 0
        }

        Write-Host "Attempt ${attempt}/${Retries}: Application is unhealthy."
    }
    catch {
        Write-Host "Attempt ${attempt}/${Retries} failed: $($_.Exception.Message)"
    }

    if ($attempt -lt $Retries) {
        Start-Sleep -Seconds $DelaySeconds
    }
}

Write-Host "Health check failed after ${Retries} attempts: $Url"
exit 1
