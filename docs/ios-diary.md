# Diario remoto en iOS

iOS descarga `GET /v1/state` con la sesión de Bocado Log almacenada en
Keychain. Esa cuenta debe ser la misma que se conectó al plugin de ChatGPT.
No se utiliza el token OAuth del MCP ni acceso directo a Supabase.

`BackendDiary` convierte los registros del servidor a `NutritionSnapshot`:
las comidas se agrupan por la fecha de consumo en la zona horaria del perfil.
Los snapshots diarios son historial corregible; los totales visibles siempre
se derivan de la fuente seleccionada. Un resumen diario no crea comidas.
Fibra se conserva en entradas y totales; los resúmenes antiguos sin ese campo
siguen siendo legibles.

El modelo usa `DailyNutritionSnapshot` y `capturedAt`; no hay operaciones de
cerrar/reabrir ni inicializadores que acepten un estado de cierre. Las claves
antiguas `closedAt` y `closedNutritionDays` se conservan únicamente en la
serialización para leer el servidor y los archivos guardados. `isClosed` en
resúmenes históricos antiguos se interpreta como evidencia de completitud, no
como un bloqueo de edición. Los eventos antiguos de cierre/reapertura se leen
como eventos de auditoría heredados.

Al registrar el primer alimento de una fecha, el servidor genera el resumen de
la fecha anterior según la zona horaria del perfil, si hay datos para resumir.
Las correcciones y los borrados posteriores generan otra versión del resumen;
no se necesita reabrir el día. Los totales visibles de comidas siguen calculándose
con los registros actuales, aunque exista un resumen previo. Un resumen histórico
de totales y las comidas son fuentes alternativas: se respeta la selección
explícita y nunca se suman entre sí.

La descarga ocurre al restaurar o iniciar una sesión, al volver al primer plano
y al deslizar para actualizar Hoy o Progreso. Cada descarga reemplaza la copia
del servidor: correcciones y borrados no se duplican ni quedan como entradas
obsoletas.

La caché está separada por ID de cuenta en
`Application Support/NutritionTracker/ServerDiary/<UUID>.json`. No modifica los
archivos históricos locales ni sube cambios al servidor. Una falla de conexión
conserva la última copia descargada y muestra un error. Al cambiar de cuenta o
cerrar sesión se limpia el diario visible; una respuesta pendiente de la cuenta
anterior se descarta. Una sesión vencida requiere iniciar sesión otra vez.

Los registros históricos del MCP pueden referenciar una operación de importación
sin un registro `import`. El adaptador agrega metadatos de procedencia solamente
a la caché para validar y mostrar ese resumen; no inventa comidas ni nutrientes.

Validación: pruebas backend de MCP → `/v1/state` para la misma cuenta,
aislamiento y snapshots; pruebas iOS del adaptador, fibra, fechas, compatibilidad,
descarga autenticada, correcciones/borrados, caché offline y cambio de cuenta.
Las pruebas iOS requieren Xcode 26 o posterior en macOS.
