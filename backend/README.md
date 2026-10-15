# Bocado Log backend

Servicio oficial: [Cloud Run con Supabase](../docs/cloud-run.md).

FastAPI, Postgres en Supabase y SQLite local, migraciones versionadas, login por contraseña y sesiones revocables. Las comidas guardadas y los datos de HealthKit permanecen disponibles en el dispositivo; registrar o consultar comidas mediante Chat requiere este servicio remoto configurado y conexión. El backend añade sincronización privada, conversación persistente y OpenAI Responses. No hay respuesta de IA simulada offline ni una clave incluida en la app. Despliegue y operación: [Cloud Run](../docs/cloud-run.md); historial de pruebas: [Render](../docs/render.md).

## Desarrollo reproducible

Python 3.11+. Desde `backend/`:

```sh
python3 -m venv .venv
.venv/bin/pip install -r requirements-dev.txt -c requirements-lock.txt
cp .env.example .env
# Editar .env y cargarlo con el shell / gestor de secretos del entorno.
.venv/bin/uvicorn app.asgi:app --host 127.0.0.1 --port 8000 --no-access-log
.venv/bin/python -m pytest -q
```

`app.asgi` lee variables del entorno. `.env` es ejemplo para compose; uvicorn no lo carga automáticamente salvo `--env-file` con python-dotenv (no dependencia). Alternativa shell: `set -a; source .env; set +a` para un archivo privado escrito por vos. Las migraciones SQL en `migrations/` se aplican al arrancar y registran versión en SQLite. El SQLite padre usa permisos 0700 y archivo 0600; no añadir ninguna carpeta de datos a Git. Una migración repetida preserva registros. Un esquema nuevo debe crear otra migración y pruebas de actualización antes de publicarse.

Hay OpenAPI y documentación interactiva en localhost `/docs` (desarrollo); no se habilitan en producción. [`docs/backend-contract.md`](../docs/backend-contract.md) define el contrato exacto para el cliente nativo.

## Autenticación y sincronización

Contraseñas scrypt con sal por usuario, sesiones aleatorias de 384 bits, hash SHA-256 en SQLite y vencimiento a los 30 días. La app conserva el token únicamente en Keychain. Logout revoca esa sesión; borrar cuenta borra todas las sesiones y datos por cascada. No hay login social, verificación por email ni recuperación de contraseña. Se verificaron 46 pruebas Python, 15 de sync Swift y 4 de HTTP/Keychain aisladas; además 3 casos de recuperación de respuesta; la última ejecución integrada de unidad en Simulator firmado reportó 117 tests sin fallos (incluye Keychain real), seguida de nuevas pruebas enfocadas de exportación; no representa aceptación física de HealthKit ni distribución. Los registros se filtran por owner en cada endpoint; UUID ajeno no concede acceso.

Sync usa revisión del propietario, versión de registro, UUID de operación y request id. Un batch es atómico; conflicto devuelve 409 y exige revisión explícita, nunca last-write-wins silencioso. El orden de batch puede reabrir un día, corregir entradas y volver a cerrar. Entradas validan cantidad/nutrientes finitos no negativos, estado, unidad, fecha con zona, conversión de porciones/densidad explícita y procedencia. Se rechazan tipos Salud/copia de muestras: HealthKit permanece local.

`POST /v1/foods` registra de forma atómica entre 1 y 20 alimentos separados. Cada elemento incluye `serving_size_grams` y los nutrientes totales de esa cantidad; la respuesta incluye cada entrada con cantidad en gramos, macros calculados y el resumen autoritativo del día. Todos los alimentos deben pertenecer al mismo día local. El endpoint usa los mismos UUIDs deterministas, revisión, recibo e idempotencia que `record_food` por MCP.

Los totales de conversación se recalculan sobre snapshots de entradas del día en zona del perfil. Calorías de etiqueta se conservan aunque difieran de 4/4/9. Si una entrada no conoce un nutriente, el total correspondiente es desconocido; vacío también es desconocido. Historial de planilla permanece separado; si existen ingesta manual e histórica se exige resolución explícita antes del contexto de IA. Selección Salud requiere además resumen nutricional específicamente consentido para esa consulta. No se suma actividad al presupuesto de comida, ni se fabrican comidas a partir de un total histórico.

## Alcance actual del registro

Desde 2026-10-09, la app registra alimentos por conversación: el asistente estima kcal y macros automáticamente según descripción, cantidad y preparación, y ofrece cantidad editable y supuestos. No pide ingreso individual de nutrientes, ni ofrece una base de alimentos, catálogo o recetas guardadas. Esas entidades anteriores permanecen compatibles en almacenamiento/sync/backups para preservar datos, pero se excluyen del contexto y schema activos de IA. Las estimaciones se revisan antes de confirmar; planificar una comida no registra consumo. Las pruebas nuevas de alcance usan un proveedor inyectado para validar contexto, schema, versiones y ausencia de writes; no se ejecutaron nuevas llamadas pagas para este cambio de prompt.

## IA y presupuesto

El servidor hace POST a `https://api.openai.com/v1/responses`, con salida JSON Schema estricta, `store:false`, contexto mínimo del día y una imagen opcional. Modelo configurable: `OPENAI_MODEL`; sin modelo/key/precios configurados devuelve 503, nunca un fake assistant. No hay token de OpenAI en iOS. Definir precios vigentes del modelo elegido en `AI_INPUT_USD_PER_MILLION` y `AI_OUTPUT_USD_PER_MILLION`; no elegir automáticamente el modelo ni adivinar precios.

La salida contiene propuestas editables y ninguna modifica la base. Confirmar es una operación posterior `/v1/sync`; solo el ack puede afirmar persistencia. Hipótesis, recomendaciones y revisión no añaden consumo, incluso si la salida del proveedor se clasifica mal en frases representativas. Correcciones requieren ID/versión de entrada del propietario; candidatos ambiguos exigen aclaración. Fotos/etiquetas producen una propuesta que aclara cantidad visual estimada y base de etiqueta; el usuario confirma. Las instrucciones del asistente excluyen diagnóstico/prescripción y exigen incertidumbre para afirmaciones clínicas sin fuentes verificables; esta entrega no ofrece búsqueda clínica ni asegura precisión de una estimación visual.

Límites diarios por usuario/global, peticiones por hora, salida máxima y timeout se configuran por entorno. Antes de la llamada se reserva conservadoramente el costo máximo (bytes de entrada + overhead JSON/schema + límite de salida + reserva de visión). Reserva atómica evita llamadas concurrentes por encima del presupuesto. Timeout o fallo conserva reserva porque el proveedor puede haber facturado; un mismo requestid fallido devuelve el mismo error y no vuelve a cobrar. Para otro intento, usuario explícitamente crea un nuevo request. Logs registran solo estado, latencia, tokens y costo estimado: sin texto, fotos, IDs personales, Health, contraseñas ni claves. `/v1/usage` solo muestra uso del propietario. Costos son estimaciones configuradas, no factura del proveedor.

Contexto Health es opt-in **por consulta y propósito**, solo peso/pasos/energía activa/minutos e ingesta nutricional resumidos para el día seleccionado. Se exige `consent:true`, propósito y fecha coincidente; tipos no permitidos, muestras, dispositivos y fuentes se rechazan. No se almacena ese contexto: receipts guardan solamente hash para idempotencia; respuesta/mensaje no debe copiar los valores de Salud sin necesidad. `store:false` no representa zero-data-retention del proveedor; revisar la [documentación oficial de datos](https://developers.openai.com/api/docs/guides/your-data) antes de habilitar la función para otros usuarios.

Revisión: ventana 14 días; al menos 10 días explícitamente cerrados/completos con kcal y tres macros conocidos, y 6 días con pesaje (mínimo 3 en cada semana); se aceptan datos manuales/importados o resúmenes Health específicos consentidos. Reporta observaciones/cobertura, ingesta diaria y actividad disponibles. Un resumen Health de un solo día no cuenta como cobertura de dos semanas. Insuficiencia bloquea propuesta de ajuste; no cambia metas automáticamente. Parámetros conservadores de producto, no prescripción médica. iOS puede complementar cobertura local consentida; backend no inventa pesajes.

## Adjuntos privados

JPEG/PNG/WebP, máximo 10 MB/20 megapíxeles, una imagen estática. iOS convierte HEIC antes de subir. Pillow decodifica y recompone JPEG nuevo hasta 2048×2048 sin EXIF/XMP/GPS/miniaturas. Solo esa copia se almacena en SQLite, máximo 100 adjuntos/100 MB por usuario. GET y DELETE exigen propietario; account delete incluye blobs. No existe CDN pública ni URL firmada compartible.

## TLS y despliegue de desarrollo

`cp .env.example .env`, configurar variables privadas y `docker compose up --build -d` desde backend. `compose.yaml` ejecuta API interna, SQLite en volumen y Caddy en `https://localhost:8443`, vinculado exclusivamente a loopback. CA interna Caddy requiere confiar su certificado para pruebas de TLS. La API solo confía forwarded headers de IP fija del proxy, y exige HTTPS para rutas privadas en producción. `/healthz` solo expone estado/esquema, sin datos privados, y permite healthcheck HTTP interno.

Para acceder desde iPhone se necesita un dominio/endpoint TLS con cadena confiable (o CA de desarrollo instalada explícitamente) y configuración de host que el usuario controle. La configuración loopback no expone el servicio a la LAN. Para un hosting público: dominio, certificados públicos, firewall, secretos separados dev/prod, backups privados y monitorización. Cambiar Caddy a certificado público y puertos del hosting es una decisión de despliegue posterior. No habilitar excepción ATS ni transportar contraseñas por HTTP en teléfono.

**Evidencia actual:** tests Python pasan y servidor Python local arrancó/healthz verificado. Docker CLI está instalado pero daemon no estaba activo y la app Docker no se encontró al intentar abrirla: compose/build no se ejecutó, despliegue container/TLS no se afirma probado. Se encontró credencial OpenAI heredada en entorno, usada solo en memoria con TLS verificado/certifi. Se verificó GET/models200 y seis llamadas Responses reales con gpt-4o-mini (consumo, hipótesis, corrección, etiqueta sintética, rerun de etiqueta y cena), total estimado USD0.0026058, latencias2.8–9.8s. El smoke native RemoteSession añadió hipótesis sin mutación, propuesta de consumo con confirmación/ack, rehidratación y borrado de cuenta (USD0.0012009); el schema expandido de peso respondió add_weight sin aclaración en un fixture real (USD0.00032715). Un fixture adicional con schema final devolvió add_activity sin aclaración y sin inventar kcal (USD0.00036210). Total estimado USD0.00449595, debajo del presupuesto de prueba USD0.02. Es costo estimado por tokens, no factura. Un resultado de etiqueta inicialmente intentó actualizar una banana existente: guard y prompt se corrigieron para impedir cualquier update/delete/close desde imágenes; rerun transcribió exactamente 400kcal/20P/40C/18F/4sat por100g y no registró ingesta. Son fixtures sintéticos, no datos/fotos reales del usuario. Pruebas de uso personal/cobertura más amplia continúan pendientes. Tampoco endpoint público. Estos gates mantienen abiertos criterios de NUT-02/07/14/15.

## Borrado, backup y restauración

No se crean backups automáticamente. Borrado elimina cuenta/sesiones/registros/mensajes/receipts/uso/adjuntos. Un contador anónimo de gasto agregado por día permanece para impedir evadir el límite global borrando cuentas; no incluye owner/ID/texto/métricas. Se usa `secure_delete` SQLite; no modifica Health original. Si operador crea backups, debe documentar retención y borrar backups al expirar: una copia ya creada no se purga mágicamente. Para backup manual, detener writes y usar SQLite `.backup` (o API SQLite backup), cifrar archivo y tratarlo como datos privados. Restaurar en base separada, correr migración/healthz/tests y verificar cuenta/propiedad antes de reemplazar producción. No copiar SQLite activo con archivos parcialmente escritos.

## Fuentes oficiales verificadas

- [Responses create](https://developers.openai.com/api/reference/python/resources/responses/methods/create)
- [Structured outputs](https://developers.openai.com/api/docs/guides/structured-outputs)
- [Images and vision](https://developers.openai.com/api/docs/guides/images-vision)
- [Pricing](https://developers.openai.com/api/docs/pricing)

Prueba API del 2026-10-08 usó [GPT-4o Mini](https://developers.openai.com/api/docs/models/gpt-4o-mini), modelo configurable con entrada de texto/imagen y structured outputs, precios oficiales consultados USD0.15/0.60 por millón de tokens. No se fijó como único modelo permitido. El runtime de smoke local usa presupuesto diario global USD0.01, sin escribir clave en archivo.


## Servicio exclusivo de tests de aceptación nativa

Desde `backend/`, `python -m tests.ui_server --port 8766` inicia un servidor sólo loopback con SQLite privado temporal y proveedor determinístico. Default 8766, puerto configurable. Usa auth/sync/propiedad/versions/guards reales; no requiere ni usa clave/modelo OpenAI, ni llama a red del proveedor. No es `app.asgi:app`, no debe desplegarse como producción y todas sus respuestas dicen Fixture. Consumo banana (150 g), corrección (eran 100 g) e hipótesis permiten tests nativos reproducibles sin costos. El fixture explica que no hace falta cerrar el día. La base temporal se elimina al cerrar el servicio. Una prueba HTTP verifica signup, sync, propuestas y ausencia de llamadas reales al proveedor. Este fixture verifica integración del cliente, no calidad de estimación del modelo.

## Postgres

`DATABASE_URL` tiene prioridad sobre el archivo `NUTRITION_DATABASE`. Las migraciones de Postgres están en `migrations/postgres/`; SQLite conserva sus migraciones existentes. No hay importación automática de archivos locales. La suite actual cubre ambos motores con `TEST_POSTGRES_URL` contra una base desechable (borra el schema por caso). Ver [operación en Cloud Run](../docs/cloud-run.md).
