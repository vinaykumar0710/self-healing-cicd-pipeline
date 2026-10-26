pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
    }

    environment {
        APP_IMAGE = "self-healing-cicd:ci-${BUILD_NUMBER}"
        CI_VENV = "/tmp/self-healing-ci-${BUILD_NUMBER}"
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Install Dependencies') {
            steps {
                sh '''
                    python3 -m venv "$CI_VENV"
                    "$CI_VENV/bin/python" -m pip install --upgrade pip
                    "$CI_VENV/bin/python" -m pip install -r requirements.txt
                '''
            }
        }

        stage('Run Unit Tests') {
            steps {
                sh '''
                    "$CI_VENV/bin/python" -m pytest -v
                '''
            }
        }

        stage('Build Docker Image') {
            steps {
                sh '''
                    docker build -t "$APP_IMAGE" .
                    docker image inspect "$APP_IMAGE" >/dev/null
                '''
            }
        }
    }

    post {
        always {
            sh '''
                if [ -n "$CI_VENV" ]; then
                    rm -rf "$CI_VENV"
                fi
            '''
        }

        success {
            echo 'CI passed: tests succeeded and the Docker image was built.'
        }

        failure {
            echo 'CI failed. Review the stage logs before proceeding.'
        }
    }
}
