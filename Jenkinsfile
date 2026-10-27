
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

                    if ($actualCommit -ne $env:DEPLOY_COMMIT) {
                        throw "Windows checkout commit does not match CI build commit."
                    }

                    $controller = Join-Path $PWD "scripts\\deploy.ps1"

                    if (-not (Test-Path $controller)) {
                        throw "Deployment controller not found: $controller"
                    }

                    $imageId = docker image inspect $env:APP_IMAGE --format '{{.Id}}'

                    if ($LASTEXITCODE -ne 0 -or -not $imageId) {
                        throw "CI image is not available in the Docker daemon: $env:APP_IMAGE"
                    }

                    Write-Host "Using image: $env:APP_IMAGE"
                    Write-Host "Image ID: $imageId"
                    Write-Host "Commit: $actualCommit"

                    $deployArgs = @{
                        CandidateVersion = "build-$env:BUILD_NUMBER"
                        CommitSha = $actualCommit
                        CandidateImage = $env:APP_IMAGE
                        RuntimeRoot = $env:RUNTIME_ROOT
                        Retries = 5
                        DelaySeconds = 2
                    }

                    if ($env:SIMULATE_POST_PROMOTION_FAILURE -eq "true") {
                        $deployArgs.SimulatePostPromotionFailure = $true
                        Write-Host "WARNING: Post-promotion failure simulation is ENABLED."
                    }

                    & $controller @deployArgs

                    if ($LASTEXITCODE -ne 0) {
                        throw "Deployment failed or recovery was not verified."
                    }

                    $health = Invoke-RestMethod `
                        -Uri "http://localhost:8080/health" `
                        -TimeoutSec 5

                    if (
                        $health.status -ne "healthy" -or
                        $health.version -ne "build-$env:BUILD_NUMBER"
                    ) {
                        throw "Post-deployment health/version verification failed."
                    }

                    Write-Host "Deployment verified: $($health.version)"
                '''
            }
        }
    }

    post {
        success {
            echo 'Pipeline succeeded: tests, image build, deployment and health verification passed.'
        }

        failure {
            echo 'Pipeline failed. Review the stage logs and deployment audit record.'
        }

        always {
            echo 'Self-Healing CI/CD pipeline finished.'
        }
    }
}
