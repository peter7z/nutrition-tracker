# Nutrition Tracker

Monorepo de una app nativa iOS en SwiftUI para registro nutricional, progreso de peso/actividad y conversación asistida. **Apple Health sigue siendo la primera prioridad de datos externos:** [NUT-01](https://github.com/peter7z/nutrition-tracker/issues/1).

## Estado

El MVP registra comidas mediante Chat conectado: el asistente propone nutrientes para revisar y la persona confirma antes de guardar. El dictado, cuando se usa, lo proporciona el teclado del sistema. La entrada manual de macros y el catálogo activo de alimentos/recetas quedan fuera del MVP. Las comidas guardadas siguen disponibles offline, pero el asistente requiere conexión y no simula respuestas. También incluye importación de Salud y planillas, tendencias de peso/actividad, sincronización privada y un backend FastAPI local. No implica que los tickets estén aceptados: sus criterios siguen abiertos hasta completar las verificaciones correspondientes. Faltan la aceptación de HealthKit con datos reales en iPhone, la integración/distribución final y un endpoint público configurado; no se afirma TestFlight.

La suite automatizada cubre lógica local, importación, sincronización y backend con fixtures. Los conteos y el resultado de la compilación integrada se documentan solo después de ejecutar la versión actual; las cifras históricas de pruebas no se usan como evidencia vigente. El simulador no sustituye la aceptación de permisos y datos personales en iPhone.

## Estructura del monorepo

- `ios/`: proyecto Xcode y fuentes de la app nativa.
- `backend/`: API FastAPI/SQLite de desarrollo para autenticación, sincronización y funciones remotas.
- `docs/`: alcance, tickets adaptados y archivo de la planificación anterior.

## Abrir y ejecutar

1. Abrir `ios/NutritionTracker.xcodeproj` en Xcode 27.0 (versión verificada en este equipo).
2. Seleccionar el esquema compartido `NutritionTracker` y un simulador iPhone con iOS 18 o superior.
3. Ejecutar con Run. La app también declara soporte iPad.

Configuración: bundle ID `com.peter7z.NutritionTracker`, nombre visible `Nutrition Tracker`; la versión/build vigentes se toman del proyecto Xcode. Se conserva el equipo de firma original `2KHYMP6SN7`; otros colaboradores deben elegir su equipo para dispositivos. HealthKit debe habilitarse también para ese App ID/perfil al firmar. El simulador no valida permisos ni datos reales del usuario.

Compilación reproducible sin firma:

```sh
xcodebuild -project ios/NutritionTracker.xcodeproj \
  -scheme NutritionTracker -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/NutritionTrackerDerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

El esquema compartido incluye `NutritionTrackerTests`. Ejecutar en un simulador disponible:

```sh
xcodebuild -project ios/NutritionTracker.xcodeproj \
  -scheme NutritionTracker \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -derivedDataPath /tmp/NutritionTrackerHealthDerivedData \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY="-" test
```

No se solicitan permisos de Salud en las pruebas; el cliente se reemplaza por fixtures. No contiene claves ni requiere servicios externos para arrancar. `xcuserdata`, builds y credenciales locales se excluyen de Git.

## Diseño

[Interfaz actual de Hoy y Chat, capturas y maquetas históricas](docs/design/home.md). El diseño original permanece como referencia histórica. La app implementa pantallas nativas de Hoy, Chat, Progreso, Salud e importación; el flujo principal de comida empieza en Chat y sus propuestas se revisan antes de guardarse. La biblioteca/catálogo se difiere del MVP; accesibilidad y comportamiento siguen sujetos a validación por ticket.

## Apple Health

La app no solicita permisos al arrancar: la conexión comienza con una acción explícita, permite seleccionar tipos y rango y usa únicamente lectura. La importación se revisa antes de guardar. Una conexión ya configurada se actualiza al volver a primer plano o al sincronizar manualmente.

Las muestras HealthKit, sus UUID y cursores quedan en el dispositivo. No se sincronizan muestras crudas; un resumen agregado de Salud solo puede compartirse con consentimiento explícito para una consulta y propósito. Desconectar detiene consultas y permite conservar o eliminar la copia local, sin modificar Salud ni perder objetivos. El éxito del diálogo de autorización no se interpreta como permiso de lectura concedido.

[Implementación, límites y validación pendiente](docs/health-import.md).

## Backlog y antecedentes

[Backlog iOS](docs/backlog.md). El orden empieza por Apple Health, luego arquitectura y registro interno, chat/fotos y validación nativa/TestFlight. El registro de comidas usa el chat como flujo principal; la entrada manual de macros y los productos/recetas guardados se difieren. Los números de issue se conservan; la definición original #1 se integra en #2 y el antiguo ticket PWA #14 se convierte a iOS. Los checkboxes permanecen sin marcar hasta contar con evidencia de aceptación, aunque ya exista código para una función.

El alcance previo se conserva en [backlog PWA archivado](docs/archive/backlog-pwa-2026-10-05.md) y [snapshot original de tickets](docs/archive/issues-pwa-2026-10-08.json). El repositorio existente conserva su historial Git; la implementación nueva se incorpora como proyecto iOS.
