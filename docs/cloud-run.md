# Bocado API en Cloud Run

Destino: Cloud Run para Python/FastAPI y MCP; la base existente sigue en
Supabase. No crear Cloud SQL ni importar/copiar tablas. Render sigue atendiendo
hasta validar el nuevo servicio y cambiar los clientes.

Proyecto elegido: `bocado-511619`; cuenta de despliegue:
`pedrozunino7@gmail.com`. Usar siempre `--project=bocado-511619` y
`--account=pedrozunino7@gmail.com` explícitos para no modificar ni usar
la configuración activa de otros proyectos.

## Acceso requerido

Usar una cuenta personal de Google Cloud y un proyecto con facturación activa.
El acceso local recomendado es `gcloud auth login`; una API key de Google no
autoriza despliegues. No hace falta entregar una clave JSON permanente.

Habilitar Cloud Run, Cloud Build, Artifact Registry y Secret Manager. El
desplegador necesita Cloud Run Source Developer, Service Usage Consumer y
Service Account User sobre la cuenta de ejecución; configurar IAM, habilitar
APIs y publicar el servicio requiere permisos administrativos adicionales.
La cuenta que construye necesita Cloud Run Builder. La cuenta de ejecución
solo necesita Secret Manager Secret Accessor sobre los secretos usados.
Confirmar las cuentas reales de build y ejecución en el proyecto antes de
otorgar estos roles.

## Configuración y secretos

Crear una cuenta de ejecución dedicada, por ejemplo `bocado-runtime`.
Guardar en Secret Manager la **misma** `DATABASE_URL` que usa Render,
`OPENAI_API_KEY` si está configurada y `APPLE_PRIVATE_KEY` si está configurada.
Usar versiones numéricas fijadas de los secretos al desplegar; no `latest`.
Preservar las restantes variables vigentes de Render (modelo, precios, límites,
Apple Services ID/Team ID/Key ID y redirect URIs). No imprimir valores privados
ni añadirlos a Git, al contexto del build o a argumentos de shell.

Inspección de Render: usa el session pooler Supabase en `us-east-1`, puerto
5432, `sslmode=verify-full` y `sslrootcert=/tmp/nutrition-supabase-ca.crt`.
Copiar también `NUTRITION_DATABASE_CA_PEM` a Secret Manager: `entrypoint.py`
materializa ese certificado al arrancar y conserva la validación TLS completa.
OpenAI y Apple web no estaban configurados en las variables de Render
inspeccionadas; no agregar claves nuevas ni habilitar funciones por defecto.

## Build reproducible con cuenta dedicada

La instalación local de gcloud no ofrece `--build-service-account` en
`run deploy`. Por eso el despliegue inicial usa Cloud Build explícitamente
con `deploy/cloudbuild.yaml`, cuenta `bocado-build` con `roles/run.builder`,
logs en Cloud Logging e imagen amd64 en Artifact Registry:

```sh
gcloud builds submit backend --config=deploy/cloudbuild.yaml \
  --substitutions=_IMAGE=us-east1-docker.pkg.dev/bocado-511619/bocado-api/api:TAG \
  --region=us-east1 --project=bocado-511619 --account=pedrozunino7@gmail.com
```

Luego usar `run deploy --image=...` en lugar de `--source=backend`. Usar un
tag nuevo para cada build; Cloud Run resuelve y fija el digest de la imagen.
La limpieza configurada en `deploy/artifact-cleanup.json` elimina imágenes
anteriores a siete días y conserva las dos versiones más recientes.

Para Supabase comprobar que la URL actual sea accesible desde Cloud Run. Su
session pooler ofrece IPv4 y conserva compatibilidad con prepared statements.
No cambiar automáticamente a transaction pooler: este no admite prepared
statements y el código actual usa psycopg con su configuración predeterminada.
Mantener TLS en la conexión. La API usa Postgres directamente: no requiere
la clave `anon` ni `service_role` de Supabase.

## Primer despliegue privado

Preparar un archivo YAML **fuera del repositorio** con variables no secretas.
Debe incluir `NUTRITION_ENV: production`, `APPLE_APP_ID: com.pedrozunino.bocado`
y las variables vigentes indicadas arriba. Inicialmente puede usar
`NUTRITION_PUBLIC_URL: https://pending.invalid`; se reemplaza antes de publicar.
El contenedor no hace llamadas salientes a ese marcador.

Ejemplo desde la raíz (reemplazar los valores y rutas):

```sh
gcloud run deploy bocado-api \
  --project=PROJECT_ID --region=us-east1 \
  --source=backend --port=8080 \
  --service-account=bocado-runtime@PROJECT_ID.iam.gserviceaccount.com \
  --cpu=1 --memory=512Mi --concurrency=4 \
  --min-instances=0 --max-instances=1 --cpu-throttling --timeout=180s \
  --env-vars-file=/PRIVATE_PATH/cloud-run-env.yaml \
  --set-secrets=DATABASE_URL=bocado-database-url:1 \
  --no-allow-unauthenticated
```

Agregar a `--set-secrets` las referencias de OpenAI/Apple cuando correspondan.
Elegir región cercana a la base Supabase; `us-east1` es solo un ejemplo.
`.gcloudignore` limita el upload a código y dependencias del runtime.
El primer arranque aplica las migraciones pendientes del backend como en
Render: revisar previamente la versión desplegada y el schema existente.
No ejecutar tests con `TEST_POSTGRES_URL` apuntando a Supabase real: borran
el schema. El máximo de una instancia y la concurrencia baja son valores
iniciales por revisión (durante despliegues pueden coexistir revisiones);
hay límites de autenticación en memoria que se reinician con la
instancia. Escalar requiere revisar esos límites y el bloqueo global de DB.

Obtener la URL y actualizarla mientras el servicio sigue privado:

```sh
gcloud run services describe bocado-api --project=PROJECT_ID \
  --region=us-east1 --format='value(status.url)'
gcloud run services update bocado-api --project=PROJECT_ID --region=us-east1 \
  --update-env-vars=NUTRITION_PUBLIC_URL=https://SERVICE_URL
```

Validar `/health` con identidad Google autorizada como Run Invoker. Cloud Run
reserva algunas rutas terminadas en `z` y bloquea `/healthz` en su frontend;
la API mantiene `/healthz` para Render/Compose y ofrece `/health` para Cloud Run.
Para
probar OAuth/MCP desde ChatGPT y Apple, publicar el endpoint; la autenticación
de usuarios sigue a cargo de Bocado, como en Render:

```sh
gcloud run services add-iam-policy-binding bocado-api \
  --project=PROJECT_ID --region=us-east1 \
  --member=allUsers --role=roles/run.invoker
```

## Validación y cambio de clientes

Comprobar healthcheck, discovery OAuth, issuer/audience con la URL nueva,
login Apple, refresh/revocación y operaciones con una cuenta sintética.
Validar imagen/adjuntos y llamadas OpenAI si están habilitadas. El MCP actual
usa `stateless_http=True` y respuestas JSON; no necesita sesiones persistentes
del proceso. Confirmar persistencia después de reiniciar el contenedor.

Actualizar `ios/nutrition-tracker/Account/AccountSession.swift` y
`bocado-log/mcp.json` solo después de validar. Si Apple web está activo,
registrar dominio/return URL nuevos en Apple Developer. Cambiar el issuer
OAuth requiere reconectar el plugin; no asumir que los tokens de Render
sirven en la URL nueva. Validar también la apertura real del widget ChatGPT.

Render y Cloud Run comparten datos: los smoke tests no deben borrar cuentas
reales. Mantener Render disponible para rollback mientras se comprueba la
app. Retirarlo una vez que los clientes usen el destino nuevo.

## Presupuesto solicitado: USD 5 mensuales

Preparado en `deploy/cloud-run-spend-cap.json`: spend cap para Cloud Run del
proyecto `bocado-511619`, con avisos al 50%, 80% y 100%. Crear o actualizar
este presupuesto usando Billing Budgets API y verificar su lectura posterior
antes de afirmar que el límite está activo. El CLI instalado no ofrece el
campo `spendCap`, por lo que una alerta creada solo por CLI no lo reemplaza.

El cap pausa nuevas solicitudes de Cloud Run cuando se alcanza el gasto
bruto estimado. Se restablece el mes siguiente. No incluye créditos/descuentos;
puede pausar el servicio aunque la factura neta sea menor por el free tier.
La aplicación no elimina los datos de Supabase al alcanzar ese umbral.

No es una garantía de factura total menor o igual a USD 5: la aplicación del
cap no es instantánea y los excedentes se cobran. Cloud Build, Artifact
Registry, Secret Manager y otros servicios no están cubiertos por el cap de
Cloud Run. Configurar también un presupuesto de alertas de USD 5 para todo
el proyecto, escala a cero, máximo de una instancia y limpieza de imágenes.
No deshabilitar la facturación de otros proyectos ni levantar automáticamente
un cap que se haya activado.

## Estado operativo — 14 de octubre de 2026

- Proyecto: `bocado-511619`, número `929368612596`, región `us-east1`.
- Servicio: `bocado-api`, URL `https://bocado-api-929368612596.us-east1.run.app`.
- Build inicial: `c212ee8d-c4c9-4894-b3da-fde3158e6f04`, `SUCCESS`.
- Build con `/health`: `14d494ed-434a-49bb-8078-d137eb839106`, `SUCCESS`.
- Revisión lista: `bocado-api-00003-mjn`, 100% del tráfico.
- Cuenta de ejecución: `bocado-runtime`; cuenta de build: `bocado-build`.
- Secretos: `bocado-database-url:1`, `bocado-database-ca:1`.
- Supabase: verificación TLS y schema 1–5 comprobados mediante consulta
  read-only. No se copiaron datos ni se alteró el schema.
- CPU: 1, RAM: 512 MiB, concurrencia: 4, timeout: 180 s, CPU por request,
  sin startup CPU boost. Máximo global y por revisión: 1; mínimo: 0.
- Spend cap Cloud Run: `9cdf1163-3ac4-4643-9cb6-3ac91c38d4f5`, USD 5/mes,
  estado leído de la API: `CONFIGURED`.
- Alertas para todo el proyecto: `f29198f7-27e5-4286-bc85-3b403da29d6d`,
  USD 5/mes con créditos incluidos, avisos al 50%, 80% y 100%.
- Servicio desplegado y listo. `/health` y discovery OAuth privados comprobados
  (HTTP 200, issuer con URL nueva). Smoke privado pasó OAuth/PKCE, autenticación
  nativa, desafío Apple, MCP/tools/resources, recurso estable del widget,
  comida CRUD/idempotencia, totales, persistencia compartida comprobada desde
  Render y refresh/revocación. Cuenta y registro OAuth sintéticos eliminados.
  El login Apple con un Apple ID real y render visual en ChatGPT no están
  acreditados por estos checks.
- Publicación autorizada explícitamente y aplicada: `allUsers` con
  `roles/run.invoker` sobre `bocado-api`. Smoke HTTP público repetido sin
  identidad Google: pasó los mismos checks de OAuth/MCP/CRUD/persistencia y
  revocación. `/health` y ambos discovery respondieron 200; `/v1/state` sin
  autenticación respondió 401. Cuenta y cliente OAuth sintéticos eliminados.
- iOS/plugin preparados en la rama, sin publicación en main. La app instalada
  necesita una nueva compilación con la URL nueva; el plugin instalado debe
  actualizar su conexión a `/mcp` de Cloud Run y reconectar OAuth. Render
  permanece disponible para rollback y para clientes con la URL anterior.
- Pruebas locales enfocadas: 32 backend aprobadas y 17 de `AccountSessionTests`
  aprobadas en iPhone 17 Pro Simulator. La suite general tenía diez fallos
  ajenos a estos cambios, reproducidos en el código anterior; no se declara
  toda la suite aprobada.

Fuentes:
- https://cloud.google.com/run/docs/deploying-source-code
- https://cloud.google.com/run/docs/container-contract
- https://cloud.google.com/run/docs/configuring/services/secrets
- https://supabase.com/docs/guides/database/connecting-to-postgres
- https://docs.cloud.google.com/billing/docs/how-to/budget-api-spend-cap
- https://docs.cloud.google.com/billing/docs/how-to/budgets-spend-caps
- https://docs.cloud.google.com/run/docs/known-issues#reserved-url-paths

## Corrección de reconexión — 14 de octubre de 2026

Se reutilizó la corrección preparada en la tarea "Reparar conexión caída",
sin publicar ni modificar los cambios pendientes de main. Fuente guardada en
`codex/cloud-run-oauth-fix`, commit `af40614`. El CSRF se mantiene estable entre
recargas/conexiones simultáneas del mismo navegador y se conserva la validación
de cookie, formulario, vinculación persistida, expiración y PKCE.

- Build `4db45ff1-c8b4-4eab-a775-83e695a8ebbd`: SUCCESS.
- Revisión `bocado-api-00004-vn4`: lista, 100% de tráfico.
- 35 pruebas enfocadas aprobadas (OAuth/Apple/arranque/health).
- Login REST y OAuth comprobados contra Render y Cloud Run con una cuenta
  sintética; ambos pasaron. Cloud Run pasó además el login con formulario
  recargado después de capturar sus campos. Datos sintéticos eliminados.
- Supabase verificado mediante consulta read-only: schema 1–5, 2 cuentas y
  68 entradas de comida existentes. No se hizo una auditoría histórica de
  integridad de cada registro; el check acredita conectividad y presencia.
- Máximo global de una instancia y spend cap USD 5/mes siguen configurados.
- Render no recibió esta corrección: su login funciona con una conexión fresca;
  las mejoras del flujo de reconexión están desplegadas solo en Cloud Run.
