"""Start the same container in Compose or behind Cloud Run's managed proxy."""
import os
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

DATABASE_CA_PATH = Path("/tmp/nutrition-supabase-ca.crt")


def prepare_database_ca(environ):
    """Materialize Render's existing CA for libpq's verify-full connection."""
    pem = environ.get("NUTRITION_DATABASE_CA_PEM", "")
    if not pem:
        return
    rootcert = parse_qs(urlsplit(environ.get("DATABASE_URL", "")).query).get("sslrootcert", [])
    if rootcert != [str(DATABASE_CA_PATH)]:
        raise ValueError("DATABASE_URL sslrootcert must match the managed database CA path")
    # Do not follow a pre-existing symlink in the writable /tmp directory.
    fd = os.open(DATABASE_CA_PATH, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as handle:
        handle.write(pem)


def command(environ):
    cloud_run = bool(environ.get("K_SERVICE"))
    database = environ.get("DATABASE_URL", "")
    if cloud_run and not database.startswith(("postgres://", "postgresql://")):
        raise ValueError("Cloud Run requires DATABASE_URL pointing to external Postgres")
    port = int(environ.get("PORT", "8000"))
    if not 1 <= port <= 65535:
        raise ValueError("PORT must be between 1 and 65535")
    # Cloud Run terminates HTTPS. Compose trusts only its Caddy proxy.
    forwarded = "*" if cloud_run else "172.28.0.2"
    return ["uvicorn", "app.asgi:app", "--host", "0.0.0.0", "--port", str(port),
            "--no-access-log", "--proxy-headers", f"--forwarded-allow-ips={forwarded}"]


if __name__ == "__main__":
    args = command(os.environ)
    prepare_database_ca(os.environ)
    os.execvp(args[0], args)
