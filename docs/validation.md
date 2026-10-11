# Validación de la limpieza iOS

10 de octubre de 2026. Esta evidencia corresponde a la retirada de funcionalidades; no acepta el plugin ni el transporte remoto de Salud.

| Requisito | Evidencia |
|---|---|
| Sin chat/registro/cámara/catálogo/importación/restauración | Módulos eliminados; Today, Progress y Settings no incluyen mutaciones; pruebas UI de navegación y rutas ausentes. |
| Historial intacto | `CompanionHistoryTests`: carga y recarga dejan bytes idénticos; schema 1 aditivo conserva comidas, peso, actividad, metas, mensajes y pendientes. Archivos corruptos o de versiones futuras se preservan. |
| Propietarios y cierres previos | `LegacyHistory` selecciona el archivo existente sin usar credenciales de red; pruebas de rutas por propietario y archivo de cierre Health limitado a su cuenta. |
| Totales y conflictos | Porciones, conversiones explícitas, calorías de etiqueta, desconocido frente a cero y fuentes superpuestas sin sumar ni guardar elecciones. |
| Salud local | `HealthSyncTests`: permisos simulados, preview, cancelación, incremental, eliminaciones, superposición, fallos, desconexión y preservación de metas antiguas. |
| Gráficas | `ProgressAnalyticsTests`: calendario, fuentes/conflictos, tendencia, huecos y cobertura. UI conserva rango y registros de consulta. |
| Accesibilidad visual | Recorridos UI en español, claro y oscuro con Dynamic Type máximo; capturas en xcresult. No sustituye una auditoría VoiceOver. |

Resultado local: **35 pruebas pasadas (31 de lógica + 4 de interfaz)** en iPhone 17 Pro/iOS 26.5 con Xcode 27.0. Resultado: `/private/tmp/NutritionTrackerCompanionFinalTests.xcresult`; log: `/private/tmp/nutrition-companion-final-tests.log`. Capturas de Hoy/Ajustes/Progreso en español, claro/oscuro y texto máximo dentro de xcresult.

Release iOS sin firma: `/private/tmp/NutritionTrackerCompanionRelease/Build/Products/Release-iphoneos/nutrition-tracker.app`; compila y `PrivacyInfo.xcprivacy` pasa `plutil`. Inspección del Info.plist del paquete confirma HealthKit de lectura, sin cámara ni excepción ATS. La CI deja de iniciar el servidor de pruebas del chat retirado; backend conserva su suite independiente.

La app no modifica tracking ni reproduce antiguos pendientes. La lectura de una versión vieja normaliza solo en memoria; no ejecuta migraciones de escritura al arrancar. Los modelos antiguos de catálogo/chat se conservan únicamente para decodificar y validar archivos existentes; sus módulos de UI, operaciones y red se retiran.

Pendientes del producto: permisos/datos reales en iPhone (NUT-01), plugin/backend/cuenta, API/caché de lectura (NUT-19), **subir el peso de Salud al servidor con consentimiento** (NUT-18), TestFlight y aceptación integral (NUT-14/NUT-15). Ninguno se declara entregado por pasar estas pruebas.

La evidencia del enfoque anterior está archivada en [validación histórica](archive/validation-ios-chat-2026-10-10.md).
