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
