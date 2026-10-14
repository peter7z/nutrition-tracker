import pytest
from entrypoint import command
import entrypoint


def test_cloud_run_honors_port_and_https_proxy():
    args = command({"K_SERVICE": "bocado-api", "PORT": "8080",
                    "DATABASE_URL": "postgresql://example.invalid/postgres"})
    assert args[args.index("--port") + 1] == "8080"
    assert "--forwarded-allow-ips=*" in args


@pytest.mark.parametrize("database", ["", "/data/local.sqlite3", "sqlite:///tmp/local"])
def test_cloud_run_never_falls_back_to_ephemeral_sqlite(database):
    with pytest.raises(ValueError, match="external Postgres"):
        command({"K_SERVICE": "bocado-api", "DATABASE_URL": database})


def test_compose_preserves_caddy_trust_and_local_storage():
    args = command({})
    assert args[args.index("--port") + 1] == "8000"
    assert "--forwarded-allow-ips=172.28.0.2" in args


@pytest.mark.parametrize("port", ["0", "65536", "invalid"])
def test_invalid_port_rejected(port):
    with pytest.raises(ValueError):
        command({"PORT": port})


def test_supabase_ca_is_created_for_existing_verify_full_url(tmp_path, monkeypatch):
    path = tmp_path / "supabase-ca.crt"
    monkeypatch.setattr(entrypoint, "DATABASE_CA_PATH", path)
    entrypoint.prepare_database_ca({
        "NUTRITION_DATABASE_CA_PEM": "test-ca",
        "DATABASE_URL": f"postgresql://example.invalid/postgres?sslmode=verify-full&sslrootcert={path}",
    })
    assert path.read_text() == "test-ca"
    assert path.stat().st_mode & 0o777 == 0o600


def test_database_ca_rejects_unexpected_output_path():
    with pytest.raises(ValueError, match="managed database CA path"):
        entrypoint.prepare_database_ca({
            "NUTRITION_DATABASE_CA_PEM": "test-ca",
            "DATABASE_URL": "postgresql://example.invalid/postgres?sslrootcert=/etc/unexpected",
        })


def test_database_ca_does_not_follow_symlinks(tmp_path, monkeypatch):
    target = tmp_path / "target"
    target.write_text("original")
    path = tmp_path / "supabase-ca.crt"
    path.symlink_to(target)
    monkeypatch.setattr(entrypoint, "DATABASE_CA_PATH", path)
    with pytest.raises(OSError):
        entrypoint.prepare_database_ca({
            "NUTRITION_DATABASE_CA_PEM": "test-ca",
            "DATABASE_URL": f"postgresql://example.invalid/postgres?sslrootcert={path}",
        })
    assert target.read_text() == "original"
