pipeline {
    agent none

    parameters {
        booleanParam(
            name: 'SIMULATE_POST_PROMOTION_FAILURE',
            defaultValue: false,
            description: 'Testing only: inject a failure after traffic promotion to verify rollback.'
        )
    }

    options {
        timestamps()
        disableConcurrentBuilds()
        skipDefaultCheckout(true)
    }

    environment {
        APP_IMAGE = "self-healing-cicd:ci-${BUILD_NUMBER}"
        CI_VENV = "/tmp/self-healing-ci-${BUILD_NUMBER}"
        APP_REPOSITORY = "https://github.com/vinaykumar0710/self-healing-cicd-pipeline.git"
        RUNTIME_ROOT = "C:\\Users\\vinay\\OneDrive\\Desktop\\Devops-projects\\self-healing-cicd"
    }

    stages {
        stage('Checkout and Test') {
            agent {
                label 'built-in'
            }

            steps {
                checkout scm

                sh '''
                    set -eu
                    python3 -m venv "$CI_VENV"
                    "$CI_VENV/bin/python" -m pip install --upgrade pip
                    "$CI_VENV/bin/python" -m pip install -r requirements.txt
                    "$CI_VENV/bin/python" -m pytest -v
                '''
            }

            post {
                always {
                    sh '''
                        if [ -n "$CI_VENV" ]; then
                            rm -rf "$CI_VENV"
                        fi
                    '''
                }
            }
        }

        stage('Build Docker Image') {
            agent {
                label 'built-in'
            }

            steps {
                checkout scm

                sh '''
                    set -eu
                    docker build -t "$APP_IMAGE" .
                    docker image inspect "$APP_IMAGE" >/dev/null
                '''

                script {
                    env.DEPLOY_COMMIT = sh(
                        script: 'git rev-parse HEAD',
                        returnStdout: true
                    ).trim()
                }

                echo "Built ${APP_IMAGE} from ${env.DEPLOY_COMMIT}"
            }
        }

        stage('Deploy on Windows Agent') {
            agent {
                label 'windows-deployer'
            }

            steps {
                deleteDir()

                git branch: 'main',
                    url: "${APP_REPOSITORY}"

                powershell '''
                    $ErrorActionPreference = "Stop"

                    $actualCommit = (git rev-parse HEAD).Trim()

                    if ($LASTEXITCODE -ne 0) {
                        throw "Unable to determine Windows checkout commit."
                    }

                    if ($actualCommit -ne $env:DEPLOY_COMMIT) {
                        throw "Windows checkout commit does not match CI build commit."
                    }

                    $controller = Join-Path $PWD "scripts\\deploy.ps1"

                    if (-not (Test-Path -LiteralPath $controller -PathType Leaf)) {
                        throw "Deployment controller not found: $controller"
                    }

                    $imageId = docker image inspect $env:APP_IMAGE --format '{{.Id}}'

                    if ($LASTEXITCODE -ne 0 -or -not $imageId) {
                        throw "CI image is not available in the Docker daemon: $env:APP_IMAGE"
                    }

                    Write-Host "Using image: $env:APP_IMAGE"
                    Write-Host "Image ID: $imageId"
                    Write-Host "Commit: $actualCommit"

                    $isRollbackTest = (
                        $env:SIMULATE_POST_PROMOTION_FAILURE -eq "true"
                    )

                    $controllerArgs = @(
                        "-NoProfile"
                        "-NonInteractive"
                        "-ExecutionPolicy"
                        "Bypass"
                        "-File"
                        $controller
                        "-CandidateVersion"
                        "build-$env:BUILD_NUMBER"
                        "-CommitSha"
                        $actualCommit
                        "-CandidateImage"
                        $env:APP_IMAGE
                        "-RuntimeRoot"
                        $env:RUNTIME_ROOT
                        "-Retries"
                        "5"
                        "-DelaySeconds"
                        "2"
                    )

                    if ($isRollbackTest) {
                        $controllerArgs += "-SimulatePostPromotionFailure"
                        Write-Host "WARNING: Post-promotion failure simulation is ENABLED."
                    }

                    # Run the controller in a child PowerShell process.
                    # Temporarily allow native stderr records to be captured
                    # without terminating this Jenkins PowerShell step.
                    $previousErrorActionPreference = $ErrorActionPreference

                    try {
                        $ErrorActionPreference = "Continue"
                        $controllerOutput = & powershell.exe @controllerArgs 2>&1
                        $controllerExitCode = $LASTEXITCODE
                    }
                    finally {
                        $ErrorActionPreference = $previousErrorActionPreference
                    }

                    $controllerOutput | ForEach-Object {
                        Write-Host $_
                    }

                    $expectedVersion = "build-$env:BUILD_NUMBER"
                    $auditFile = Join-Path $env:RUNTIME_ROOT "logs\\deployments.jsonl"

                    if ($isRollbackTest) {
                        # The injected failure must cause a nonzero controller exit.
                        if ($controllerExitCode -eq 0) {
                            throw "Rollback test failed: controller unexpectedly returned success after injected failure."
                        }

                        if (-not (Test-Path -LiteralPath $auditFile -PathType Leaf)) {
                            throw "Rollback test failed: audit log not found."
                        }

                        $auditLines = @(Get-Content -LiteralPath $auditFile)

                        if ($auditLines.Count -eq 0) {
                            throw "Rollback test failed: audit log is empty."
                        }

                        try {
                            $record = $auditLines[-1] | ConvertFrom-Json -ErrorAction Stop
                        }
                        catch {
                            throw "Rollback test failed: latest audit record is not valid JSON."
                        }

                        # Confirm that this build's failure and rollback were recorded.
                        if (
                            $record.candidate_version -ne $expectedVersion -or
                            $record.commit_sha -ne $actualCommit -or
                            $record.candidate_image -ne $env:APP_IMAGE -or
                            $record.deployment_status -ne "FAILED" -or
                            $record.rollback_status -ne "VERIFIED" -or
                            $record.error -notmatch "Simulated failure after traffic promotion"
                        ) {
                            throw "Rollback test failed: latest audit record does not confirm this build's expected verified rollback."
                        }

                        # Verify that the previous release is serving traffic.
                        $health = Invoke-RestMethod `
                            -Uri "http://localhost:8080/health" `
                            -TimeoutSec 5

                        $stateFile = Join-Path $env:RUNTIME_ROOT "deployment-state.json"

                        if (-not (Test-Path -LiteralPath $stateFile -PathType Leaf)) {
                            throw "Rollback test failed: deployment state file not found."
                        }

                        $state = Get-Content -LiteralPath $stateFile -Raw |
                            ConvertFrom-Json -ErrorAction Stop

                        if (
                            $health.status -ne "healthy" -or
                            $health.version -ne $record.previous_version -or
                            $state.active_version -ne $record.previous_version -or
                            $state.active_color -ne $record.previous_color -or
                            $state.last_known_good_image -ne $record.previous_image
                        ) {
                            throw "Rollback test failed: previous release health or deployment state could not be verified."
                        }

                        Write-Host "ROLLBACK TEST PASSED: injected failure was detected; the previous release was restored and verified."

                        # The nonzero controller exit was expected and verified.
                        $global:LASTEXITCODE = 0
                    }
                    else {
                        if ($controllerExitCode -ne 0) {
                            throw "Deployment failed or recovery was not verified. Controller exit code: $controllerExitCode"
                        }

                        $health = Invoke-RestMethod `
                            -Uri "http://localhost:8080/health" `
                            -TimeoutSec 5

                        if (
                            $health.status -ne "healthy" -or
                            $health.version -ne $expectedVersion
                        ) {
                            throw "Post-deployment health/version verification failed."
                        }

                        Write-Host "Deployment verified: $($health.version)"
                        $global:LASTEXITCODE = 0
                    }
                '''
            }
        }
    }

    post {
        success {
            script {
                if (params.SIMULATE_POST_PROMOTION_FAILURE) {
                    echo 'ROLLBACK TEST PASSED: Injected failure detected; previous release restored and verified.'
                } else {
                    echo 'PIPELINE PASSED: Tests, image build, deployment and health verification completed successfully.'
                }
            }
        }

        failure {
            echo 'PIPELINE FAILED: Review the stage logs and deployment audit record.'
        }
    }
}