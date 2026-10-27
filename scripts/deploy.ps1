
param(
    [Parameter(Mandatory = $true)]
    [string]$CandidateVersion,

    [string]$CommitSha = "local",

    [string]$CandidateImage,

    [string]$RuntimeRoot,

    [ValidateSet("healthy", "unhealthy")]
    [string]$CandidateHealth = "healthy",

    [ValidateRange(1, 100)]
    [int]$Retries = 5,

    [ValidateRange(0, 300)]
    [int]$DelaySeconds = 2,

    [switch]$SimulatePostPromotionFailure
)

$ErrorActionPreference = "Stop"

# Repository containing this script and the application source.
$ScriptRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

# Persistent runtime directory containing deployment state, Compose,
# Nginx configuration, and audit logs.
if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
    $Root = $ScriptRoot
}
else {
    if (-not (Test-Path -LiteralPath $RuntimeRoot -PathType Container)) {
        throw "RuntimeRoot directory does not exist: $RuntimeRoot"
    }

    $Root = (Resolve-Path -LiteralPath $RuntimeRoot).Path
}

$StateFile = Join-Path $Root "deployment-state.json"
$UpstreamFile = Join-Path $Root "proxy\upstream.conf"
$AuditFile = Join-Path $Root "logs\deployments.jsonl"
$ComposeFile = Join-Path $Root "compose.yaml"

$Network = "self-healing-cicd_default"
$ComposeProject = "self-healing-cicd"
$CandidateName = "self-healing-candidate"

# Validate required runtime files.
if (-not (Test-Path -LiteralPath $StateFile -PathType Leaf)) {
    throw "Deployment state file not found: $StateFile"
}

if (-not (Test-Path -LiteralPath $UpstreamFile -PathType Leaf)) {
    throw "Nginx upstream file not found: $UpstreamFile"
}

if (-not (Test-Path -LiteralPath $ComposeFile -PathType Leaf)) {
    throw "Compose file not found: $ComposeFile"
}

# Ensure the audit log exists, including on a fresh checkout.
$LogDirectory = Split-Path -Parent $AuditFile

if (-not (Test-Path -LiteralPath $LogDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
}

if (-not (Test-Path -LiteralPath $AuditFile -PathType Leaf)) {
    New-Item -ItemType File -Path $AuditFile -Force | Out-Null
}

# Read the last successfully deployed release.
$OriginalStateText = Get-Content -LiteralPath $StateFile -Raw
$State = $OriginalStateText | ConvertFrom-Json

$PreviousColor = [string]$State.active_color
$PreviousVersion = [string]$State.active_version
$PreviousImage = [string]$State.last_known_good_image

if ($PreviousColor -notin @("blue", "green")) {
    throw "Invalid active_color in deployment-state.json."
}

if ([string]::IsNullOrWhiteSpace($PreviousVersion)) {
    throw "active_version is missing from deployment-state.json."
}

if ([string]::IsNullOrWhiteSpace($PreviousImage)) {
    throw "last_known_good_image is missing from deployment-state.json."
}

# Choose the inactive color for the next release.
$CandidateColor = if ($PreviousColor -eq "blue") {
    "green"
}
else {
    "blue"
}

$CandidateService = "app-$CandidateColor"

$SafeSha = $CommitSha -replace '[^a-zA-Z0-9_.-]', ''

if (-not $SafeSha) {
    $SafeSha = "local"
}

# Generate an image tag only when Jenkins did not supply one.
$UseProvidedCandidateImage = -not [string]::IsNullOrWhiteSpace(
    $CandidateImage
)

if (-not $UseProvidedCandidateImage) {
    $UniqueTag = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmssfff")
    $CandidateImage = "self-healing-cicd:candidate-$SafeSha-$UniqueTag"
}

$StartedAt = (Get-Date).ToUniversalTime().ToString("o")

$DeploymentStatus = "FAILED"
$RollbackStatus = "NOT_REQUIRED"
$ErrorMessage = $null
$CandidateStarted = $false
$InactiveServiceModified = $false
$PromotionAttempted = $false
$InactiveBefore = $null
$Proxy = $null

$OldUpstream = Get-Content -LiteralPath $UpstreamFile -Raw

function Invoke-DockerChecked {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$DockerArgs
    )

    & docker @DockerArgs

    if ($LASTEXITCODE -ne 0) {
        throw "Docker command failed: docker $($DockerArgs -join ' ')"
    }
}

function Invoke-ComposeService {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Service,

        [Parameter(Mandatory = $true)]
        [string]$Image,

        [Parameter(Mandatory = $true)]
        [string]$Version,

        [Parameter(Mandatory = $true)]
        [string]$Health
    )

    $Prefix = if ($Service -eq "app-blue") {
        "BLUE"
    }
    else {
        "GREEN"
    }

    $ImageVar = "${Prefix}_IMAGE"
    $VersionVar = "${Prefix}_VERSION"
    $HealthVar = "${Prefix}_HEALTH_STATUS"

    $OldImageEnv = [Environment]::GetEnvironmentVariable(
        $ImageVar, "Process"
    )

    $OldVersionEnv = [Environment]::GetEnvironmentVariable(
        $VersionVar, "Process"
    )

    $OldHealthEnv = [Environment]::GetEnvironmentVariable(
        $HealthVar, "Process"
    )

    try {
        [Environment]::SetEnvironmentVariable(
            $ImageVar, $Image, "Process"
        )

        [Environment]::SetEnvironmentVariable(
            $VersionVar, $Version, "Process"
        )

        [Environment]::SetEnvironmentVariable(
            $HealthVar, $Health, "Process"
        )

        Invoke-DockerChecked @(
            "compose",
            "--project-name", $ComposeProject,
            "--project-directory", $Root,
            "-f", $ComposeFile,
            "up", "-d", "--no-build", "--force-recreate",
            $Service
        )
    }
    finally {
        [Environment]::SetEnvironmentVariable(
            $ImageVar, $OldImageEnv, "Process"
        )

        [Environment]::SetEnvironmentVariable(
            $VersionVar, $OldVersionEnv, "Process"
        )

        [Environment]::SetEnvironmentVariable(
            $HealthVar, $OldHealthEnv, "Process"
        )
    }
}

function Test-ServiceHealth {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Service,

        [Parameter(Mandatory = $true)]
        [string]$Image
    )

    for ($Attempt = 1; $Attempt -le $Retries; $Attempt++) {
        $Output = & docker run --rm `
            --network $Network `
            --entrypoint python `
            $Image `
            -c "import urllib.request; print(urllib.request.urlopen('http://${Service}:5000/health', timeout=2).read().decode())" 2>$null

        if (
            $LASTEXITCODE -eq 0 -and
            $Output -match '"status":\s*"healthy"'
        ) {
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
    # Confirm that the expected Compose network already exists.
    $NetworkExists = @(
        & docker network ls --format "{{.Name}}"
    ) -contains $Network

    if ($LASTEXITCODE -ne 0 -or -not $NetworkExists) {
        throw "Required Docker network does not exist: $Network"
    }

    # Capture the inactive service's existing configuration for recovery.
    $InactiveId = (
        & docker compose `
            --project-name $ComposeProject `
            --project-directory $Root `
            -f $ComposeFile `
            ps -q $CandidateService
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
            $OldInactiveVersion = $Entry.Substring(
                "APP_VERSION=".Length
            )
        }

        if ($Entry -like "HEALTH_STATUS=*") {
            $OldInactiveHealth = $Entry.Substring(
                "HEALTH_STATUS=".Length
            )
        }
    }

    # Use the CI-built image when supplied. Otherwise build locally.
    if ($UseProvidedCandidateImage) {
        Write-Host "Using CI-built candidate image: $CandidateImage"

        & docker image inspect $CandidateImage *> $null

        if ($LASTEXITCODE -ne 0) {
            throw "CI candidate image not found in the Docker daemon: $CandidateImage"
        }
    }
    else {
        Write-Host "Building candidate image: $CandidateImage"

        Invoke-DockerChecked @(
            "build",
            "-t", $CandidateImage,
            $ScriptRoot
        )
    }

    # Remove any stale temporary candidate container.
    & docker rm -f $CandidateName 2>$null | Out-Null

    # Start an isolated candidate without changing production traffic.
    Invoke-DockerChecked @(
        "run", "-d",
        "--name", $CandidateName,
        "--network", $Network,
        "-e", "APP_VERSION=$CandidateVersion",
        "-e", "HEALTH_STATUS=$CandidateHealth",
        $CandidateImage
    ) | Out-Null

    $CandidateStarted = $true

    # Test the candidate before modifying the inactive stable service.
    $Healthy = $false

    for ($Attempt = 1; $Attempt -le $Retries; $Attempt++) {
        $Output = @()
        $DockerExitCode = -1

        $PreviousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"

        try {
            $Output = & docker run --rm `
                --network $Network `
                --entrypoint python `
                $CandidateImage `
                -c "import urllib.request; print(urllib.request.urlopen('http://self-healing-candidate:5000/health', timeout=2).read().decode())" 2>&1

            $DockerExitCode = $LASTEXITCODE
        }
        catch {
            $Output += $_.ToString()
        }
        finally {
            $ErrorActionPreference = $PreviousErrorActionPreference
        }

        $OutputText = $Output | ForEach-Object { "$_" } | Out-String

        if (
            $DockerExitCode -eq 0 -and
            $OutputText -match '"status":\s*"healthy"'
        ) {
            $Healthy = $true
            break
        }

        Write-Host "Candidate health attempt ${Attempt}/${Retries} failed (exit code: $DockerExitCode)."
        Write-Host $OutputText

        if ($Attempt -lt $Retries) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    if (-not $Healthy) {
        throw "Candidate failed health checks. Active traffic remains unchanged."
    }

    # Replace only the inactive stable service.
    Write-Host "Candidate is healthy. Preparing $CandidateService."

    $InactiveServiceModified = $true

    Invoke-ComposeService `
        -Service $CandidateService `
        -Image $CandidateImage `
        -Version $CandidateVersion `
        -Health "healthy"

    if (
        -not (
            Test-ServiceHealth `
                -Service $CandidateService `
                -Image $CandidateImage
        )
    ) {
        throw "Stable candidate service failed health checks."
    }

    # Locate the Nginx proxy belonging to the same Compose project.
    $Proxy = (
        & docker compose `
            --project-name $ComposeProject `
            --project-directory $Root `
            -f $ComposeFile `
            ps -q proxy
    ).Trim()

    if ($LASTEXITCODE -ne 0 -or -not $Proxy) {
        throw "Nginx proxy container was not found."
    }

    # Route traffic to the candidate only after its health check passes.
    $NewUpstream = @"
upstream flask_app {
    server ${CandidateService}:5000;
}
"@

    $PromotionAttempted = $true

    Set-Content `
        -LiteralPath $UpstreamFile `
        -Value $NewUpstream `
        -NoNewline

    Invoke-DockerChecked @("exec", $Proxy, "nginx", "-t")
    Invoke-DockerChecked @("exec", $Proxy, "nginx", "-s", "reload")

    # Verify that the public endpoint serves the candidate version.
    $PublicVerified = $false

    for ($Attempt = 1; $Attempt -le $Retries; $Attempt++) {
        try {
            $Public = Invoke-RestMethod `
                -Uri "http://localhost:8080/version" `
                -TimeoutSec 3

            if ($Public.version -eq $CandidateVersion) {
                $PublicVerified = $true
                break
            }
        }
        catch {
            Write-Host "Public verification attempt ${Attempt}/${Retries} failed."
        }

        if ($Attempt -lt $Retries) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    if (-not $PublicVerified) {
        throw "Public endpoint verification failed after promotion."
    }

    # Fault injection for testing rollback after traffic promotion.
    if ($SimulatePostPromotionFailure) {
        throw "Simulated failure after traffic promotion."
    }

    # Record the new last-known-good release only after verification.
    [ordered]@{
        active_color = $CandidateColor
        active_version = $CandidateVersion
        last_known_good_image = $CandidateImage
    } | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding utf8

    $DeploymentStatus = "SUCCESS"
    $RollbackStatus = "NOT_REQUIRED"

    Write-Host "Deployment succeeded: $CandidateVersion ($CandidateColor)."
}
catch {
    $ErrorMessage = ($_ | Out-String).Trim()
    Write-Host "Deployment failed: $ErrorMessage"
    Write-Host "Full exception details:"
    Write-Host ($_ | Format-List * -Force | Out-String)
    Write-Host "Script stack trace: $($_.ScriptStackTrace)"

    $RecoveryErrors = @()

    # Restore the previous Nginx route if promotion was attempted.
    if ($PromotionAttempted) {
        try {
            Set-Content `
                -LiteralPath $UpstreamFile `
                -Value $OldUpstream `
                -NoNewline

            $Proxy = (
                & docker compose `
                    --project-name $ComposeProject `
                    --project-directory $Root `
                    -f $ComposeFile `
                    ps -q proxy
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

    # Restore the original deployment state.
    try {
        Set-Content `
            -LiteralPath $StateFile `
            -Value $OriginalStateText `
            -Encoding utf8
    }
    catch {
        $RecoveryErrors += "State restoration failed: $($_.Exception.Message)"
    }

    # Verify that the previously deployed version serves healthy traffic.
    try {
        $Recovery = Invoke-RestMethod `
            -Uri "http://localhost:8080/health" `
            -TimeoutSec 5

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
    # Write one JSON audit record for every deployment attempt.
    $AuditRecord = [ordered]@{
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
    }

    $AuditRecord |
        ConvertTo-Json -Compress |
        Add-Content -LiteralPath $AuditFile -Encoding utf8

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
