from fastapi.testclient import TestClient
from app.config import Settings
from app.main import create_app


def test_cloud_run_health_alias_checks_db_and_preserves_render_path(tmp_path):
    app = create_app(Settings(database=str(tmp_path / "health.sqlite3"),
                              environment="production", public_url="https://bocado.example"))
    with TestClient(app, base_url="http://localhost") as client:
        for path in ("/health", "/healthz"):
            response = client.get(path)
            assert response.status_code == 200
            assert response.json() == {"status": "ok", "schema_version": 5}
        assert client.get("/v1/state").status_code == 400
