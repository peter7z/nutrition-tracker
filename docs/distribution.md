# Distribución y aceptación de Bocado iOS

> **Cambio de producto — 10 de octubre de 2026:** este documento conserva implementación/evidencia del enfoque anterior. El alcance vigente se define en [especificación de producto](product.md) y el backlog: companion iOS de consulta/Salud, registro desde el plugin de ChatGPT y widgets futuros con Extensions. Sus referencias a chat, registro o edición en iOS no son requisitos vigentes. La adaptación del código y de los contratos está pendiente.

Estado de preparación: 9 de octubre de 2026. El archivo vigente es **1.0 (build 3)**, firmado para desarrollo; build 2 es histórico. La suite actual valida el flujo chat-first. Este documento distingue compilación, instalación de desarrollo, aceptación funcional y distribución. Ninguno de estos resultados constituye un build TestFlight.

## Validación del cambio de identidad (12 de octubre de 2026)

- Debug en iPhone 17 Pro Simulator iOS 26.5: 56 tests de unidad y 1 test de UI, sin fallos; resultado `/private/tmp/BocadoRenameTests.xcresult`.
- Release para iOS: `BUILD SUCCEEDED` con `CODE_SIGNING_ALLOWED=NO`; paquete `/private/tmp/BocadoRenameRelease/Build/Products/Release-iphoneos/Bocado.app`.
- Ambos paquetes: Bundle ID `com.pedrozunino.bocado`, nombre y ejecutable `Bocado`; nombres y descripciones de Salud efectivos comprobados en inglés y español.
- Manifest de privacidad válido y firma ad-hoc del paquete Simulator verificada. Esta firma no valida distribución en dispositivos.
- Backend: 11 tests de login Apple pasaron con el nuevo audience; `.env.example` y el default `APPLE_APP_ID` están actualizados. No se modificaron variables del servidor ni registros de Apple Developer/App Store Connect.

## Identidad y recursos

- Nombre de la app iOS: **Bocado**. Bundle ID: `com.pedrozunino.bocado`.
- Producto generado: `Bocado.app`. Los nombres internos del proyecto, esquema y módulo Swift se conservan para compatibilidad con las herramientas existentes.
- El [Bundle ID identifica la app para iOS](https://developer.apple.com/documentation/BundleResources/Information-Property-List/CFBundleIdentifier). La instalación anterior conserva sus datos; este cambio no migra su contenedor ni sus permisos. Los identificadores persistidos de archivos, Keychain y metadata de HealthKit se mantienen para compatibilidad, pero no conceden acceso al contenedor de la app anterior.
- Antes de distribuir, registrar/configurar el nuevo App ID con HealthKit y Sign in with Apple y generar su perfil de firma. El código del repositorio no acredita esa configuración en Apple Developer ni App Store Connect.
- Proyecto: `ios/NutritionTracker.xcodeproj`, esquema compartido `NutritionTracker`, iOS 18+; iPhone e iPad.
- Team de desarrollo conservado: `2KHYMP6SN7`. Confirmar que tiene membresía vigente, acuerdos aceptados y acceso a App Store Connect antes de distribuir.
- Icono: `AppIcon.appiconset/AppIcon.png`, 1024 × 1024, RGB opaco, hoja blanca y anillo sobre verde bosque. El catálogo genera los tamaños del sistema; no contiene texto ni un borde redondeado dibujado.
- Base de marketing: 1.0; incrementar `CURRENT_PROJECT_VERSION` antes de cada upload. Verificar los valores efectivos con `xcodebuild -showBuildSettings`; no dar por publicado un número escrito en documentación.
- HealthKit: lectura solamente; la descripción de uso debe estar localizada en inglés/español. Cámara contextual para capturar una imagen; PhotosPicker para selección limitada del sistema. Revisar los textos efectivos en el producto, no únicamente las claves del catálogo.
- Manifest: `ios/nutrition-tracker/PrivacyInfo.xcprivacy`. Debe aparecer en la raíz del `.app` construido.

## Alcance de producto para esta aceptación

La entrada de comida del MVP empieza en Chat o dictado: el asistente calcula una propuesta para revisar y la persona confirma la cantidad antes de registrarla. No hay formulario manual de macros ni catálogo de productos o recetas en el MVP; NUT-09 está diferido. La pantalla compacta de revisión permite confirmar la cantidad ofrecida, pero no cambia crudo/cocido: para corregir esa información se conversa con el asistente y se recalculan los nutrientes. Los registros manuales de peso y actividad sí continúan dentro de NUT-12.

## Validación automática

`.github/workflows/ci.yml` ejecuta pytest del backend en Ubuntu y tests de unidad/UI en un iOS Simulator disponible del runner macOS. Los tests usan host firmado ad-hoc en Simulator para probar Keychain real; esa firma no habilita distribución ni demuestra aceptación en un iPhone. Selecciona explícitamente un Xcode instalado de versión 26 o posterior: el [inventario oficial macOS 15](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md) aún declara Xcode 16.4 por defecto, que no verifica la configuración de aislamiento de Swift 6.2 del proyecto. Selecciona dispositivo desde `simctl list ... --json`; no supone un nombre o runtime local. El workflow usa versiones de [checkout](https://github.com/actions/checkout), [setup-python](https://github.com/actions/setup-python) y [upload-artifact](https://github.com/actions/upload-artifact) verificadas en sus repositorios oficiales, y los runtimes dependen de la [imagen del runner](https://github.com/actions/runner-images).

Los UITests usan `--ui-testing` con almacenamiento temporal aislado, `--reset-ui-testing` para limpiar cada escenario y `--ui-testing-offline` para el estado offline. Estas opciones se habilitan solamente en Debug y no consultan Salud real. No usar el almacenamiento personal ni aceptar permisos de Salud para ejecutar una prueba de UI.

Ejemplo local, después de elegir un UDID disponible con `xcrun simctl list devices available`:

```sh
xcodebuild -project ios/NutritionTracker.xcodeproj -scheme NutritionTracker \
  -configuration Debug -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' \
  -derivedDataPath /private/tmp/NutritionTrackerValidation \
  -resultBundlePath /private/tmp/NutritionTrackerValidation.xcresult \
  -parallel-testing-enabled NO -testLanguage en -testRegion US \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY="-" test
```

`SIMULATOR_UDID` es un valor a reemplazar, no un dispositivo configurado. Usar un resultBundlePath nuevo en cada ejecución. No añadir claves OpenAI ni certificados de distribución al workflow de validación. Sus artefactos de test tienen retención de siete días y usan datos ficticios.

**Evidencia actual (9 de octubre):** `/private/tmp/nutrition-chat-first-unit.log` pasó 126 XCTest, sin fallos; `/private/tmp/nutrition-chat-first-final.log` pasó los cinco UITests, sin fallos; `backend/README.md` registra 46 pruebas Python pasadas. El flujo de chat del UITest propuso una comida, corrigió su cantidad, conservó una sola entrada y verificó el cierre/reinicio/reapertura. `/private/tmp/nutrition-chat-first-ipad-screen.log` pasó dos UITests de navegación y layout en iPad, incluyendo ambas orientaciones y texto máximo. Esta evidencia no acredita HealthKit real, VoiceOver, un servicio HTTPS público ni distribución/TestFlight.

## Archivo firmado y TestFlight

1. Abrir el proyecto en Xcode, elegir el esquema compartido y **Any iOS Device**. Revisar Signing & Capabilities, team, bundle y HealthKit; incrementar el build.
2. Ejecutar **Product → Archive** en Release. Alternativa, con el team ya configurado en Xcode:

   ```sh
   xcodebuild -project ios/NutritionTracker.xcodeproj -scheme NutritionTracker \
     -configuration Release -destination 'generic/platform=iOS' \
     -archivePath /private/tmp/NutritionTracker.xcarchive \
     -allowProvisioningUpdates archive
   ```

3. Confirmar que el archivo contiene `Products/Applications/Bocado.app`, Info.plist con versión/build correctos, icono y manifest. Verificar firma con `codesign --verify --deep --strict` y entitlements con `codesign -d --entitlements :- RUTA_APP`; HealthKit debe seguir presente. El provisioning de **distribución** debe ser válido para el team y bundle; una instalación de desarrollo no lo demuestra.
4. En Organizer, generar/revisar **Privacy Report** y usar **Validate App**. Resolver errores de permisos, manifest, dependencias, icono, export compliance y signing. Revisar el `.app` efectivo antes de cambiar declaraciones. Apple describe el [manifest de privacidad](https://developer.apple.com/documentation/bundleresources/privacy_manifest_files) y las [APIs de razón obligatoria](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).
5. Crear o verificar la app correspondiente en App Store Connect. Publicar una política de privacidad accesible públicamente y completar App Privacy a partir del backend realmente habilitado. `docs/privacy.md` es una fuente editable; un archivo de un repo privado no satisface la URL pública requerida por [Apple](https://developer.apple.com/app-store/app-privacy-details/).
6. En Organizer, **Distribute App → App Store Connect → Upload**. Verificar procesamiento exitoso, versión/build y grupo de testers en TestFlight. Para testers externos, completar la revisión beta exigida por Apple.
7. Instalar **ese build** desde TestFlight, anotar versión/build y ejecutar la aceptación siguiente. Un upload procesado sin instalación no demuestra que el build sea instalable.

El archive `NutritionTrackerMVP-1.0-2.xcarchive` es de build 2 (8 de octubre) y queda como historial. El archive vigente del código chat-first actualizado, `/private/tmp/NutritionTrackerMVP-1.0-3-Chat.xcarchive`, se generó el 9 de octubre y pasó `ARCHIVE SUCCEEDED` y `codesign --verify --deep --strict`. Contiene versión 1.0/build 3, mínimo iOS 18, iPhone/iPad, icono, manifest, HealthKit y descripciones localizadas de cámara/Salud. Su perfil es **de desarrollo** (`get-task-allow=true`), no de distribución. La exportación de build 3 del 9 de octubre con `ios/Configuration/ExportOptions-AppStore.plist` y método `app-store-connect` falló por **No Accounts** y falta de perfil iOS App Store para el bundle, igual que el intento histórico de build 2; esto no se ha resuelto ni se ha subido build 3. `devicectl` instaló de nuevo build 3 desde el archive actualizado en el iPhone autorizado. El primer intento de abrirlo falló por dispositivo bloqueado y el último por conexión XPC de CoreDevice no disponible. No hay lanzamiento físico, upload ni instalación TestFlight acreditados. No se automatiza publicación ni se incluyen credenciales de App Store Connect en Git.

## Aceptación en dispositivo y accesibilidad

Registrar evidencia sin copiar salud personal a logs, capturas públicas o artefactos de CI. Para Salud, anotar tipos, rango, estado del flujo y resultado agregado de la prueba; no publicar valores personales.

| Área | Prueba y evidencia requerida | Estado de esta preparación |
|---|---|---|
| Instalación de desarrollo | Firma e instalación/launch en el iPhone autorizado | Build 3 actualizado se instaló con `devicectl`; launch físico pendiente (primer intento bloqueado; último intento sin conexión XPC de CoreDevice) |
| Salud real | Elegir tipos/rango, continuar, permitir o denegar lectura, revisar y confirmar; refrescar; desconectar/borrar copia sin alterar originales | Aceptación con datos reales no acreditada |
| Comida por Chat | Describir comida, revisar cantidad y nutrientes propuestos, confirmar el registro, corregir mediante Chat y validar totales al cerrar/reabrir | UITest final pasó; una comida sintética se corrigió y continuó como una sola entrada al cerrar, relanzar y reabrir |
| Persistencia y recuperación | Relanzamiento, migración/backup válido y fallo de restore sin perder estado; imágenes y Salud opt-in cuando formen parte de la copia | Tests de dominio existentes; completar aceptación UI de archivos |
| Planilla | File picker, preview, confirmar, verificar fechas/valores/conflictos, deshacer lote preservando registros posteriores | Validar un archivo real elegido por el usuario |
| Fotos | Cámara en iPhone y PhotosPicker, negar cámara, cancelar picker, confirmar propuesta editable, borrar imagen y verificar límites/metadata | Validación física pendiente |
| Chat/servicio | Login, HTTPS, consulta real, timeout/budget, corrección confirmada, logout/cambio de cuenta sin mezcla | Smoke HTTP/Keychain/sync/Responses real con fixtures pasó en localhost; endpoint HTTPS público/accesible desde iPhone y aceptación física pendientes |
| Offline | Leer lo guardado, conservar borrador; no inventar respuesta; reintentar explícitamente al recuperar red | UITest de borrador offline incluido; probar transición real de red |
| Accesibilidad | VoiceOver: orden, etiquetas/valores, botones y controles; Dynamic Type máximo; contraste claro/oscuro, teclado/safe areas | Revisión manual de pantallas finales pendiente |
| iPad | Portrait/landscape, formularios, chat, picker y share sheet | 2 UITests pasaron en iPad Pro 13 (M5): navegación y capturas claras/oscuras, texto máximo y ambas orientaciones. Picker, share sheet y formularios con datos siguen pendientes |
| TestFlight | Archivo firmado validado, upload procesado e instalación del mismo build | Pendiente |

Los tickets NUT-01, NUT-14 y NUT-15 mantienen abiertos los criterios que dependen de esas evidencias. La documentación y el icono no reemplazan las pruebas.
