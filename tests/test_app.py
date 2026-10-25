
import app.main as application


def test_home_endpoint(client):
    response = client.get("/")
    assert response.status_code == 200
    assert response.json["application"] == "Self-Healing CI/CD Demo"


def test_health_endpoint_is_healthy(client, monkeypatch):
    monkeypatch.setattr(application, "HEALTH_STATUS", "healthy")
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json["status"] == "healthy"


def test_health_endpoint_is_unhealthy(client, monkeypatch):
    monkeypatch.setattr(application, "HEALTH_STATUS", "unhealthy")
    response = client.get("/health")
    assert response.status_code == 503
    assert response.json["status"] == "unhealthy"


def test_version_endpoint(client):
    response = client.get("/version")
    assert response.status_code == 200
    assert "version" in response.json
