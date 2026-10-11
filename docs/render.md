# Backend en Render

`render.yaml` describe la API Python y Postgres 16, ambos en Virginia con
planes gratuitos para pruebas. No se usa disco persistente en la API.
`DATABASE_URL` se configura con la conexión interna de Postgres; nunca
incluir credenciales en Git. `.render` es una clave local ignorada por Git.

## Persistencia

El backend usa Postgres cuando `DATABASE_URL` contiene una URL PostgreSQL.
SQLite se conserva para desarrollo local y archivos existentes; no se
importan automáticamente bases locales ni información de Apple Health.
Las migraciones específicas de Postgres se ejecutan al arrancar dentro
de una transacción. Un bloqueo transaccional coordina migraciones y
operaciones para conservar revisiones, idempotencia y reservas de presupuesto.
Este bloqueo serializa operaciones de base de datos: apropiado para esta
etapa, deberá revisarse antes de aumentar el tráfico.

## Deploy

Build desde `backend/` con dependencias fijadas. Uvicorn escucha en `$PORT`;
Render termina TLS. Se confían encabezados reenviados en este entorno
administrado; no reutilizar el comando para un servidor público directo.
`NUTRITION_ENV=production` desactiva documentación y requiere HTTPS.
`/healthz` comprueba acceso a la base. Auto deploy tras checks de `main`.
No se configura OpenAI: el análisis legado responde que no está configurado.
El plugin, OAuth y el envío de peso de Apple Health siguen pendientes.

## Pruebas

La suite verifica SQLite y Postgres cuando se configura `TEST_POSTGRES_URL`.
**Usar exclusivamente una base desechable:** cada caso Postgres borra y
recrea el schema `public`. CI usa un servicio Postgres 16 aislado.

## Límites de la etapa gratuita

Postgres gratuito vence 30 días después de crearse y no tiene backups.
La base creada el 10 de octubre vence el 9 de noviembre de 2026 a las
22:48 de Uruguay (10 de noviembre 01:48 UTC). Antes de esa fecha, migrar
o pasar a un plan pago para conservar datos. La API gratuita puede dormir.
No usar esta configuración como almacenamiento definitivo de datos reales.

Referencias: https://render.com/docs/free,
https://render.com/docs/postgresql, https://render.com/docs/blueprint-spec.

## Servicio publicado

- API: https://nutrition-tracker-api-cljy.onrender.com
- Healthcheck: https://nutrition-tracker-api-cljy.onrender.com/healthz
- Workspace: `nutrition`.
- Servicio: `srv-db5emoqd0e5s73f6on6g`.
- Base: `dpg-db5em1d9fdbs73cjrssg-a`, Postgres 16, plan free.
- Commit de backend: `8b9a7603516ad9692e84b436558d6e3fefaa85fc`.
- CI: https://github.com/peter7z/nutrition-tracker/actions/runs/38103222249
- 87 pruebas locales y backend CI, más validación de iOS/Release en CI.

El backend remoto se probó con datos sintéticos, sin conectar Salud real.
La prueba inicial rechazó correctamente un registro de peso sin ID (422);
quedó una cuenta sintética vacía de esa comprobación. La prueba completa
usa un peso válido, verifica persistencia tras redeploy y elimina su cuenta.

## Endpoint del plugin

La primera implementación incorpora `/mcp` en el mismo servicio, SDK Python
`mcp==1.30.0` (protocolos hasta `2025-11-25` con negociación). La migración 3
agrega clientes, autorizaciones y tokens OAuth sin reemplazar registros.
`NUTRITION_PUBLIC_URL` fija el issuer y audience del recurso, sin depender del
Host que envía un cliente. En producción debe ser HTTPS. El consentimiento
abre `/oauth/connect`; discovery está en `/.well-known/oauth-authorization-server`
y `/.well-known/oauth-protected-resource/mcp`. La autorización usa DCR y PKCE,
no requiere un client secret ni una API key OpenAI. Tokens y códigos se guardan
por hash; los refresh rotan, y account delete elimina tokens por cascada.

Las herramientas tienen scopes y annotations explícitas. La API previa y
MCP usan cuentas compartidas, pero sus tokens no son intercambiables.
Paquete, instalación y límites: [plugin/README.md](../plugin/README.md).


### Verificación pública — 10 de octubre de 2026

Render desplegó `a06d63fe9a9580392c8103f77020396b653cc9fc` mediante
`dep-db5f9kjbc2fs738ndggg`. [CI](https://github.com/peter7z/nutrition-tracker/actions/runs/38105072707)
aprobó backend (99 pruebas, SQLite/Postgres) e iOS. La prueba HTTP pública
verificó discovery, OAuth/PKCE, registro/corrección/borrado, totales, reintentos
idempotentes, aislamiento de cuentas/scopes y renovación/revocación. Las dos
cuentas sintéticas se eliminaron al terminar. Instalación y conversación real
en ChatGPT siguen pendientes; no se usaron datos reales de Salud.
