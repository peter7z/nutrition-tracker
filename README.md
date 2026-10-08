# Nutrition Tracker

Monorepo de una app nativa iOS en SwiftUI para registrar comidas por chat y fotos, visualizar calorías y macros y seguir peso y actividad. **La primera tarea es importar los datos de Apple Health con HealthKit:** [NUT-01](https://github.com/peter7z/nutrition-tracker/issues/1).

## Estado

Scaffold inicial de Xcode revisado. Contiene una pantalla de bienvenida localizada en español/inglés, esquema compartido y configuración HealthKit de lectura. No incluye todavía importación, persistencia, chat, backend ni login. Los 15 tickets del MVP permanecen abiertos.

## Estructura del monorepo

- `ios/`: proyecto Xcode y fuentes de la app nativa.
- `backend/`: espacio reservado para el servidor futuro; no implementado todavía.
- `docs/`: alcance, tickets adaptados y archivo de la planificación anterior.

## Abrir y ejecutar

1. Abrir `ios/NutritionTracker.xcodeproj` en Xcode 27.0 (versión verificada en este equipo).
2. Seleccionar el esquema compartido `NutritionTracker` y un simulador iPhone con iOS 18 o superior.
3. Ejecutar con Run. La app también declara soporte iPad.

Configuración: bundle ID `com.peter7z.NutritionTracker`, nombre visible `Nutrition Tracker`, versión 1.0 (build 1). Se conserva el equipo de firma original `2KHYMP6SN7`; otros colaboradores deben elegir su equipo para dispositivos. HealthKit debe habilitarse también para ese App ID/perfil al firmar. El simulador no valida permisos ni datos reales del usuario.

Compilación reproducible sin firma:

```sh
xcodebuild -project ios/NutritionTracker.xcodeproj \
  -scheme NutritionTracker -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/NutritionTrackerDerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

Los tests de importación y negocio se incorporan con sus implementaciones. El scaffold no tiene target de tests. No contiene claves ni requiere servicios externos para arrancar. `xcuserdata`, builds y credenciales locales se excluyen de Git.

## Apple Health

El proyecto declara `com.apple.developer.healthkit` y una descripción localizada de lectura. No solicita permisos al arrancar, no consulta ni escribe en Salud y no habilita entrega en segundo plano. NUT-01 implementa conexión voluntaria, selección de datos, importación histórica/incremental, persistencia, fuentes y reconciliación sin duplicados.

## Backlog y antecedentes

[Backlog iOS completo](docs/backlog.md). El orden empieza por Apple Health, luego arquitectura/registro, chat/fotos y validación nativa/TestFlight. Los números de issue se conservan; la definición original #1 se integra en #2 y el antiguo ticket PWA #14 se convierte a iOS.

El alcance previo se conserva en [backlog PWA archivado](docs/archive/backlog-pwa-2026-10-05.md) y [snapshot original de tickets](docs/archive/issues-pwa-2026-10-08.json). El repositorio existente conserva su historial Git; la implementación nueva se incorpora como proyecto iOS.
