
param(
    [Parameter(Mandatory = $true)]
    [string]$CandidateVersion,

    [string]$CommitSha = "local",

    [ValidateSet("healthy", "unhealthy")]
    [string]$CandidateHealth = "healthy",

    [ValidateRange(1, 100)]
    [int]$Retries = 5,

    [ValidateRange(0, 300)]
    [int]$DelaySeconds = 2,

    [switch]$SimulatePostPromotionFailure
)

$ErrorActionPreference = "Stop"

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$StateFile = Join-Path $Root "deployment-state.json"
$UpstreamFile = Join-Path $Root "proxy\upstream.conf"
$AuditFile = Join-Path $Root "logs\deployments.jsonl"
$ComposeFile = Join-Path $Root "compose.yaml"
$Network = "self-healing-cicd_default"
$CandidateName = "self-healing-candidate"

if (-not (Test-Path $StateFile)) {
    throw "Deployment state file not found: $StateFile"
}
if (-not (Test-Path $UpstreamFile)) {
    throw "Nginx upstream file not found: $UpstreamFile"
}
if (-not (Test-Path $AuditFile)) {
    throw "Audit log not found: $AuditFile"
}

$OriginalStateText = Get-Content $StateFile -Raw
$State = $OriginalStateText | ConvertFrom-Json

$PreviousColor = [string]$State.active_color
$PreviousVersion = [string]$State.active_version
$PreviousImage = [string]$State.last_known_good_image

if ($PreviousColor -notin @("blue", "green")) {
    throw "Invalid active_color in deployment-state.json."
}

$CandidateColor = if ($PreviousColor -eq "blue") {
    "green"
} else {
    "blue"
}
$CandidateService = "app-$CandidateColor"

$SafeSha = $CommitSha -replace '[^a-zA-Z0-9_.-]', ''
if (-not $SafeSha) {
    $SafeSha = "local"
}

$UniqueTag = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmssfff")
$CandidateImage = "self-healing-cicd:candidate-$SafeSha-$UniqueTag"
$StartedAt = (Get-Date).ToUniversalTime().ToString("o")

$DeploymentStatus = "FAILED"
$RollbackStatus = "NOT_REQUIRED"
$ErrorMessage = $null
$CandidateStarted = $false
$InactiveServiceModified = $false
$PromotionAttempted = $false
$InactiveBefore = $null
$Proxy = $null
$OldUpstream = Get-Content $UpstreamFile -Raw

function Invoke-DockerChecked {
    param([string[]]$DockerArgs)

    & docker @DockerArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Docker command failed: docker $($DockerArgs -join ' ')"
    }
}

function Invoke-ComposeService {
    param(
        [string]$Service,
        [string]$Image,
        [string]$Version,
        [string]$Health
    )

    $Prefix = if ($Service -eq "app-blue") {
        "BLUE"
    } else {
        "GREEN"
    }

    $ImageVar = "${Prefix}_IMAGE"
    $VersionVar = "${Prefix}_VERSION"
    $HealthVar = "${Prefix}_HEALTH_STATUS"

    $OldImageEnv = [Environment]::GetEnvironmentVariable($ImageVar, "Process")
    $OldVersionEnv = [Environment]::GetEnvironmentVariable($VersionVar, "Process")
    $OldHealthEnv = [Environment]::GetEnvironmentVariable($HealthVar, "Process")

    try {
        [Environment]::SetEnvironmentVariable($ImageVar, $Image, "Process")
        [Environment]::SetEnvironmentVariable($VersionVar, $Version, "Process")
        [Environment]::SetEnvironmentVariable($HealthVar, $Health, "Process")

        Invoke-DockerChecked @(
            "compose",
            "--project-directory", $Root,
            "-f", $ComposeFile,
            "up", "-d", "--no-build", "--force-recreate", $Service
        )
    }
    finally {
        [Environment]::SetEnvironmentVariable($ImageVar, $OldImageEnv, "Process")
        [Environment]::SetEnvironmentVariable($VersionVar, $OldVersionEnv, "Process")
        [Environment]::SetEnvironmentVariable($HealthVar, $OldHealthEnv, "Process")
    }
}

function Test-ServiceHealth {
    param(
        [string]$Service,
        [string]$Image
    )

    for ($Attempt = 1; $Attempt -le $Retries; $Attempt++) {
        $Output = & docker run --rm `
            --network $Network `
            --entrypoint python `
            $Image `
            -c "import urllib.request; print(urllib.request.urlopen('http://${Service}:5000/health', timeout=2).read().decode())" 2>$null

        if ($LASTEXITCODE -eq 0 -and $Output -match '"status":\s*"healthy"') {
            Write-Host "Health check passed for $Service."
            return $true
        }

        Write-Host "Health check attempt ${Attempt}/${Retries} failed for $Service."

        if ($Attempt -lt $Retries) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    return $false
}

try {
    # Capture the inactive service's previous configuration.
    $InactiveId = (
        & docker compose --project-directory $Root -f $ComposeFile ps -q $CandidateService
    ).Trim()

    if ($LASTEXITCODE -ne 0 -or -not $InactiveId) {
        throw "Cannot find inactive service $CandidateService."
    }

    $InspectOutput = & docker inspect $InactiveId
    if ($LASTEXITCODE -ne 0) {
        throw "Cannot inspect inactive service $CandidateService."
    }

    $InactiveBefore = ($InspectOutput | ConvertFrom-Json)[0]
    $OldInactiveImage = [string]$InactiveBefore.Config.Image
    $OldInactiveVersion = "v1"
    $OldInactiveHealth = "healthy"

    foreach ($Entry in $InactiveBefore.Config.Env) {
        if ($Entry -like "APP_VERSION=*") {
            $OldInactiveVersion = $Entry.Substring("APP_VERSION=".Length)
        }
        if ($Entry -like "HEALTH_STATUS=*") {
            $OldInactiveHealth = $Entry.Substring("HEALTH_STATUS=".Length)
        }
    }

    Write-Host "Building candidate image: $CandidateImage"
    Invoke-DockerChecked @("build", "-t", $CandidateImage, $Root)

    # Remove any stale temporary candidate, if present.
    & docker rm -f $CandidateName 2>$null | Out-Null

    # Start candidate separately; active traffic is not changed here.
    Invoke-DockerChecked @(
        "run", "-d",
        "--name", $CandidateName,
        "--network", $Network,
        "-e", "APP_VERSION=$CandidateVersion",
        "-e", "HEALTH_STATUS=$CandidateHealth",
        $CandidateImage
    ) | Out-Null

    $CandidateStarted = $true

    $Healthy = $false

    for ($Attempt = 1; $Attempt -le $Retries; $Attempt++) {
        $Output = & docker run --rm `
            --network $Network `
            --entrypoint python `
            $CandidateImage `
            -c "import urllib.request; print(urllib.request.urlopen('http://self-healing-candidate:5000/health', timeout=2).read().decode())" 2>$null

        if ($LASTEXITCODE -eq 0 -and $Output -match '"status":\s*"healthy"') {
            $Healthy = $true
            break
        }

        Write-Host "Candidate health attempt ${Attempt}/${Retries} failed."

        if ($Attempt -lt $Retries) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    if (-not $Healthy) {
        throw "Candidate failed health checks. Active traffic remains unchanged."
    }

    # Candidate passed its initial health check.
    # Recreate only the inactive Compose service.
    Write-Host "Candidate is healthy. Preparing $CandidateService."

    $InactiveServiceModified = $true

    Invoke-ComposeService `
        -Service $CandidateService `
        -Image $CandidateImage `
        -Version $CandidateVersion `
        -Health "healthy"

    if (-not (Test-ServiceHealth -Service $CandidateService -Image $CandidateImage)) {
        throw "Stable candidate service failed health checks."
    }

    $Proxy = (
        & docker compose --project-directory $Root -f $ComposeFile ps -q proxy
    ).Trim()

    if ($LASTEXITCODE -ne 0 -or -not $Proxy) {
        throw "Nginx proxy container was not found."
    }

    # Promote only after the stable service is healthy.
    $NewUpstream = @"
upstream flask_app {
    server ${CandidateService}:5000;
}
"@

    $PromotionAttempted = $true
    Set-Content -Path $UpstreamFile -Value $NewUpstream -NoNewline

    Invoke-DockerChecked @("exec", $Proxy, "nginx", "-t")
    Invoke-DockerChecked @("exec", $Proxy, "nginx", "-s", "reload")

    # Verify that public traffic reaches the candidate.
    $PublicVerified = $false

    for ($Attempt = 1; $Attempt -le $Retries; $Attempt++) {
        try {
            $Public = Invoke-RestMethod `
                "http://localhost:8080/version" `
                -TimeoutSec 3

            if ($Public.version -eq $CandidateVersion) {
                $PublicVerified = $true
                break
            }
        }
        catch {
            # Retry below.
        }

        if ($Attempt -lt $Retries) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    if (-not $PublicVerified) {
        throw "Public endpoint verification failed after promotion."
    }

    # Test-only fault injection: force rollback after traffic has switched.
    if ($SimulatePostPromotionFailure) {
        throw "Simulated failure after traffic promotion."
    }

    # Update deployment state only after promotion is verified.
    [ordered]@{
        active_color = $CandidateColor
        active_version = $CandidateVersion
        last_known_good_image = $CandidateImage
    } | ConvertTo-Json | Set-Content $StateFile -Encoding utf8

    $DeploymentStatus = "SUCCESS"
    $RollbackStatus = "NOT_REQUIRED"

    Write-Host "Deployment succeeded: $CandidateVersion ($CandidateColor)."
}
catch {
    $ErrorMessage = $_.Exception.Message
    Write-Host "Deployment failed: $ErrorMessage"

    $RecoveryErrors = @()

    # Restore the previous Nginx route if promotion was attempted.
    if ($PromotionAttempted) {
        try {
            Set-Content -Path $UpstreamFile -Value $OldUpstream -NoNewline

            $Proxy = (
                & docker compose --project-directory $Root -f $ComposeFile ps -q proxy
            ).Trim()

            if ($LASTEXITCODE -ne 0 -or -not $Proxy) {
                throw "Proxy container unavailable during rollback."
            }

            Invoke-DockerChecked @("exec", $Proxy, "nginx", "-t")
            Invoke-DockerChecked @("exec", $Proxy, "nginx", "-s", "reload")
        }
        catch {
            $RecoveryErrors += "Route rollback failed: $($_.Exception.Message)"
        }
    }

    # Restore the inactive service's original image and environment.
    if ($InactiveServiceModified -and $InactiveBefore) {
        try {
            Invoke-ComposeService `
                -Service $CandidateService `
                -Image $OldInactiveImage `
                -Version $OldInactiveVersion `
                -Health $OldInactiveHealth
        }
        catch {
            $RecoveryErrors += "Inactive service restoration failed: $($_.Exception.Message)"
        }
    }

    # Restore the recorded state if it was changed before an error.
    try {
        Set-Content -Path $StateFile -Value $OriginalStateText -Encoding utf8
    }
    catch {
        $RecoveryErrors += "State restoration failed: $($_.Exception.Message)"
    }

    # Verify the old release is again serving public traffic.
    try {
        $Recovery = Invoke-RestMethod "http://localhost:8080/health" -TimeoutSec 5

        if (
            $Recovery.status -ne "healthy" -or
            $Recovery.version -ne $PreviousVersion
        ) {
            throw "Previous release verification failed."
        }
    }
    catch {
        $RecoveryErrors += "Previous release verification failed: $($_.Exception.Message)"
    }

    if ($RecoveryErrors.Count -gt 0) {
        $RollbackStatus = "CRITICAL_FAILURE"
        $ErrorMessage += " | " + ($RecoveryErrors -join " | ")
    }
    elseif ($PromotionAttempted -or $InactiveServiceModified) {
        $RollbackStatus = "VERIFIED"
    }
    else {
        $RollbackStatus = "PREVIOUS_RELEASE_PRESERVED"
    }
}
finally {
    [ordered]@{
        commit_sha = $CommitSha
        candidate_color = $CandidateColor
        candidate_version = $CandidateVersion
        candidate_image = $CandidateImage
        previous_color = $PreviousColor
        previous_version = $PreviousVersion
        previous_image = $PreviousImage
        deployment_status = $DeploymentStatus
        rollback_status = $RollbackStatus
        started_at = $StartedAt
        finished_at = (Get-Date).ToUniversalTime().ToString("o")
        error = $ErrorMessage
    } | ConvertTo-Json -Compress | Add-Content -Path $AuditFile -Encoding utf8

    if ($CandidateStarted) {
        & docker rm -f $CandidateName 2>$null | Out-Null
    }
}

if ($DeploymentStatus -ne "SUCCESS") {
    if ($RollbackStatus -eq "CRITICAL_FAILURE") {
        Write-Error "CRITICAL: Deployment failed and recovery was not fully verified."
    }

    exit 1
}

exit 0
