
import os
from flask import Flask, jsonify

app = Flask(__name__)

APP_VERSION = os.getenv("APP_VERSION", "dev")
HEALTH_STATUS = os.getenv("HEALTH_STATUS", "healthy")


@app.route("/")
def home():
    return jsonify({
        "application": "Self-Healing CI/CD Demo",
        "version": APP_VERSION,
        "message": "Application is running"
    })


@app.route("/health")
def health():
    if HEALTH_STATUS != "healthy":
        return jsonify({
            "status": "unhealthy",
            "version": APP_VERSION
        }), 503

    return jsonify({
        "status": "healthy",
        "version": APP_VERSION
    }), 200


@app.route("/version")
def version():
    return jsonify({
        "version": APP_VERSION
    })


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
