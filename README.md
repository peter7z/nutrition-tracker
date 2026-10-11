# Nutrition Tracker

Monorepo de un companion iOS para Apple Health y visualización de progreso, un backend compartido y un **plugin de ChatGPT** para consultar y registrar tracking. Apple Health mantiene la primera prioridad: [NUT-01](https://github.com/peter7z/nutrition-tracker/issues/1).

## Producto objetivo — 10 de octubre de 2026

**iOS sincroniza Salud y muestra datos/gráficas; todo registro y corrección se hace desde ChatGPT mediante el plugin.** La app no tendrá chat propio, formularios de tracking ni catálogo de alimentos. ChatGPT estima nutrientes y el backend valida/persiste herramientas MCP. El MCP es parte del plugin; una fase posterior incorpora widgets de calorías, peso y progreso mediante **ChatGPT Extensions**.

La decisión completa, los flujos y límites están en [especificación de producto](docs/product.md); los tickets vigentes están en [backlog](docs/backlog.md).

**Estado del código:** iOS se reduce a consulta de datos existentes, gráficas y conexión/sincronización local con Salud. Se retiran chat, registro/edición, cámara, catálogo, importación/restauración y el cliente antiguo de mutaciones. Los esquemas y archivos previos se conservan para consulta. Backend FastAPI conserva la implementación de desarrollo anterior; la primera implementación del plugin incorpora paquete, herramientas MCP y OAuth; la instalación/conversación en ChatGPT, lectura remota iOS y sincronización de Salud al servidor siguen pendientes. **El peso importado de Apple Health sí debe enviarse al servidor (NUT-18)**. El backend de pruebas está desplegado en Render con Postgres; ver [deploy y límites](docs/render.md). Plugin, widgets y TestFlight siguen pendientes.

## Estructura del monorepo

- `ios/`: proyecto Xcode y fuentes de la app nativa.
- `backend/`: API FastAPI/Postgres (SQLite para desarrollo local) para autenticación, sincronización y funciones remotas.
- `plugin/`: paquete privado 0.1.0, instrucciones/skill, configuración OAuth/MCP y guía de conexión; widgets futuros.
- `docs/`: especificación de producto, tickets vigentes y planificación histórica.

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

## Diseño y alcance

[Especificación de producto](docs/product.md): Hoy, Progreso, Datos y Ajustes/Salud como consulta. [Capturas del diseño anterior](docs/design/home.md) se conservan como evidencia histórica; su chat y botones de registro no representan el nuevo alcance.

## Apple Health

La lectura local sigue siendo la primera tarea y puede funcionar sin login ni servidor. Se eligen tipos/rango, se revisa el historial y se mantiene una copia local con procedencia y cursores, sin escribir en Salud.

Para que el plugin consulte Salud, el nuevo alcance agrega consentimiento de sincronización al backend, tipos/rango limitados, revocación y scopes específicos. Esa sincronización remota todavía requiere implementación; no equivale al envío agregado por consulta del enfoque anterior. Ver NUT-18 y [producto](docs/product.md#sincronización-y-privacidad-de-salud).

## Backlog y antecedentes

[Backlog vigente](docs/backlog.md). Se conservan NUT-01 a NUT-15 reformulados y se agregan tickets de servidor MCP, OAuth, sincronización de Salud, caché de consulta iOS, entrega del plugin y widgets. NUT-09 se retira como no planificado. Las tareas de integración permanecen abiertas hasta aceptar el nuevo alcance.

El enfoque anterior se conserva en [backlog iOS con chat](docs/archive/backlog-ios-chat-2026-10-09.md) y [snapshot de issues](docs/archive/issues-ios-chat-2026-10-10.json), además del [backlog PWA original](docs/archive/backlog-pwa-2026-10-05.md). La migración preserva historial y datos existentes.

Sign in with Apple en iOS y cuenta compartida con el plugin: [configuración y estado](docs/apple-sign-in.md). La vinculación automática usa el email verificado de Apple. El acceso web requiere configurar Services ID y key en Render.
