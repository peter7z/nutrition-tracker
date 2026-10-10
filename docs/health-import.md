# Apple Health — primera implementación

> **Cambio de producto — 10 de octubre de 2026:** este documento conserva implementación/evidencia del enfoque anterior. El alcance vigente se define en [especificación de producto](product.md) y el backlog: companion iOS de consulta/Salud, registro desde el plugin de ChatGPT y widgets futuros con Extensions. Sus referencias a chat, registro o edición en iOS no son requisitos vigentes. La adaptación del código y de los contratos está pendiente.

Entrega del 8 de octubre de 2026. NUT-01 sigue abierto hasta validar permisos, firma e importación del historial personal en iPhone real.

## Flujo disponible

1. Conectar Apple Health desde Hoy o Ajustes.
2. Elegir tipos: peso, pasos, energía activa/en reposo, ejercicio, entrenamientos, energía ingerida, proteína, carbohidratos, grasas y saturadas.
3. Elegir 30/90 días, un año, todo el historial o una fecha de inicio. Perfil inicial America/Montevideo.
4. Continuar abre la solicitud nativa de lectura, sin permisos de escritura.
5. Revisar cantidad de observaciones, cobertura temporal y fuentes. Una consulta vacía no permite distinguir falta de registros de falta de permisos.
6. Confirmar guarda la copia local; cancelar descarta muestras y cursores sin modificar lo previamente guardado. Cambiar rango/tipos reconstruye la selección y reemplaza la copia solo al confirmar.
7. Hoy muestra nutrientes y actividad por día; Progreso lista observaciones originales por tipo con fecha, fuente y dispositivo. Ajustes define objetivos opcionales, sincroniza y desconecta.

## Contrato y persistencia

`HealthKitClient` usa consultas async de HealthKit. La importación lee cambios en páginas de 500 objetos mediante `HKAnchoredObjectQueryDescriptor`, preservando UUID, unidades normalizadas, fechas y fuente/dispositivo. Cursor opaco archivado con secure coding. El predicado de inicio permanece estable, sin un límite final que se mueva entre sincronizaciones.

`HealthSyncModel` prepara una copia de trabajo y solo publica el estado tras guardado exitoso. Altas/reintentos se identifican por UUID; borrados eliminan la observación. Si falla cualquier consulta o el guardado, el estado y los cursores previos se conservan. Un número de operación impide que una respuesta tardía vuelva a conectar o restaure datos después de desconectar/cancelar.

`HealthFileRepository` guarda un snapshot JSON de esquema 1 en Application Support/NutritionTracker/health-v1.json, con escritura atómica y protección completa. El directorio queda excluido del backup. Un archivo inválido o de esquema no soportado se reporta, no se reemplaza silenciosamente. Las muestras originales, sus UUID y los cursores no se envían a servidores ni a IA; no hay logging de datos ni metadatos personales. Si una consulta concreta requiere contexto de Salud, solo se envían agregados mínimos después de consentimiento específico; no se incluyen muestras, fuentes ni dispositivos.

Los resúmenes nutricionales locales de días cerrados y los contextos consentidos pendientes se preservan aparte cuando cambia el rango de importación o se desconecta la fuente. No se envían mediante tracking sync. Eliminar la copia local de Health también elimina esas copias y contextos; los originales de Apple Health permanecen intactos. Esta conservación está cubierta por `HealthNutritionClosureTests`.

Esta persistencia inicial guarda el snapshot completo: la lectura está paginada, pero la revisión y el guardado requieren tener el conjunto en memoria. El rango inicial es de 90 días. Antes de ampliar el uso a historiales masivos, medir memoria/tiempo y migrar a persistencia transaccional por registros en NUT-02; no se promete importación en segundo plano ni reanudación de una importación cancelada.

## Agregación y UX

Pasos, energía y nutrientes diarios provienen de `HKStatisticsCollectionQueryDescriptor` con cumulativeSum. No se suman manualmente muestras superpuestas de iPhone/Watch. Entrenamientos guardan duración/tipo y no suman energía otra vez. Los pesajes se conservan individualmente; Hoy usa el último disponible anterior al momento actual y muestra su fecha.

Los valores ausentes son nil: se muestran con guion y texto de ausencia, nunca como cero. Un cero explícito sí es un dato. La ingesta no se deduce de actividad ni de energía en reposo, y los nutrientes históricos no inventan comidas. Los objetivos no existen hasta que el usuario los guarda; la barra se limita visualmente al 100% y el excedente se muestra en kcal.

“Lectura configurada” describe la conexión solicitada, no acredita permisos otorgados. Desconectar detiene consultas futuras y permite borrar o conservar la copia local; una copia conservada es histórica y puede quedar desactualizada. Revocar permisos en Salud no borra automáticamente datos que ya se importaron: pueden eliminarse en Ajustes.

## Verificación

La suite `HealthSyncTests` tiene 16 pruebas, como la nota de la primera fase. `HealthNutritionClosureTests` agrega cinco pruebas de cierre/conservación local. El último log integrado disponible pasó 120 XCTest en total, sin fallos (`/private/tmp/nutrition-mvp-full-validation.log`). Las pruebas Health cubren vista previa sin guardado, cancelación, paginación, UUID repetidos y pesajes distintos simultáneos, estadísticas combinadas, borrados y nil, fallos de guardado/sync, respuesta de autorización vacía, respuestas tardías, reconfiguración, zona horaria y cero real, archivo corrupto, conversiones, serialización/detención de cursor, objetivos, separación ejercicio/ingesta y cierres nutricionales locales. Estos son fixtures y dobles de HealthKit, no aceptación del servicio del sistema.

Falta probar en iPhone: provisioning HealthKit, diálogo y permisos parciales/denegados, importación y estadísticas contra Salud con el historial personal, fuentes superpuestas, permiso revocado y borrados reales. No se cierra el ticket por compilar o por pasar fixtures. La reconciliación con registros manuales o planilla se integra cuando existan esas fuentes; esta entrega contiene únicamente datos de Salud.

## Referencias de Apple

- [Autorización y privacidad de lectura](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data).
- [Consultas ancladas](https://developer.apple.com/documentation/healthkit/hkanchoredobjectquerydescriptor).
- [Estadísticas por intervalos](https://developer.apple.com/documentation/healthkit/hkstatisticscollectionquerydescriptor).
