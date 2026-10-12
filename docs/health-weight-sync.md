# Peso de Apple Health en la cuenta

La app pide autorización adicional en Ajustes → Compartir peso con tu cuenta.
Leer HealthKit localmente no autoriza subir sus datos. Esta función solamente
envía peso en kg, fecha e ID de la medición; no envía comidas, actividad,
identificadores de dispositivo ni datos de otras métricas.

La primera carga recorre el historial de peso que HealthKit permite leer,
independientemente del rango de consulta local. Las siguientes usan un cursor
propio de consultas ancladas de HealthKit, con nuevas mediciones y borrados
reales. No se deducen borrados de una lista vacía, un cambio de rango o una
desconexión de Salud. Apple no permite distinguir falta de datos de falta de
permiso de lectura.

Antes de cada envío se persisten el lote, un ID de petición y su próximo cursor.
El cursor avanza solamente después de recibir el recibo del servidor. Los fallos
de red se reintentan al volver a la app, actualizar Hoy/Progreso o tocar
Sincronizar peso. No se promete sincronización en segundo plano en esta etapa.
El estado de la carga está separado por cuenta y excluido del backup del teléfono.

El backend tiene dos tablas nuevas: `health_weight_consent` y `health_weights`.
Cada medición está identificada por usuario e ID de HealthKit. Reenviar el mismo
lote devuelve el mismo recibo; otra carga del mismo ID no duplica el peso. Los
borrados conservan una marca para impedir que un dispositivo atrasado vuelva
a crear una medición eliminada. Los pesos manuales permanecen independientes.

- `GET /v1/health/weight/consent`: estado de autorización y versión.
- `POST /v1/health/weight/consent`: autorizar o detener; `delete_data` elimina la copia remota.
- `POST /v1/health/weight/sync`: lote con `request_id`, `consent_version`, `samples` y `deleted_ids`.

La autorización se verifica antes de aceptar o repetir un lote. Detener y volver
a autorizar cambia su versión, invalidando cargas antiguas. Detener conserva la
copia ya subida; borrar la copia además la elimina de las consultas. Si la
revocación se hace offline, el teléfono deja de subir inmediatamente y guarda
la revocación para enviarla cuando recupere conexión.

`/v1/state` entrega la copia como registros de peso con fuente `appleHealth` y
`sourceSampleID`. iOS evita duplicarla con la misma medición local de Salud.
La web la muestra por fecha y MCP la consulta con `get_day` y `get_progress`.
Una medición de Salud se corrige en Salud; no se modifica mediante el endpoint
genérico de registros manuales.

La migración 5 habilita RLS en las dos tablas PostgreSQL y revoca acceso público,
anon y authenticated. La API identifica al dueño mediante su sesión. No se
conecta iOS directamente a Supabase.
