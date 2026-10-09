# Distribución y aceptación de Nutrition Tracker

Estado de preparación: 9 de octubre de 2026. El archivo vigente es **1.0 (build 3)**, firmado para desarrollo; build 2 es histórico. La suite actual valida el flujo chat-first. Este documento distingue compilación, instalación de desarrollo, aceptación funcional y distribución. Ninguno de estos resultados constituye un build TestFlight.

## Identidad y recursos

- Nombre: **Nutrition Tracker**. Bundle ID: `com.peter7z.NutritionTracker`.
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

**Evidencia actual (9 de octubre):** `/private/tmp/nutrition-chat-first-unit.log` pasó 126 XCTest, sin fallos; `/private/tmp/nutrition-chat-first-final.log` pasó los cinco UITests, sin fallos; `backend/README.md` registra 46 pruebas Python pasadas. El flujo de chat del UITest propuso una comida, corrigió su cantidad, conservó una sola entrada y verificó el cierre/reinicio/reapertura. Esta evidencia no acredita HealthKit real, VoiceOver, layout iPad, un servicio HTTPS público ni distribución/TestFlight.

## Archivo firmado y TestFlight

1. Abrir el proyecto en Xcode, elegir el esquema compartido y **Any iOS Device**. Revisar Signing & Capabilities, team, bundle y HealthKit; incrementar el build.
2. Ejecutar **Product → Archive** en Release. Alternativa, con el team ya configurado en Xcode:

   ```sh
   xcodebuild -project ios/NutritionTracker.xcodeproj -scheme NutritionTracker \
     -configuration Release -destination 'generic/platform=iOS' \
     -archivePath /private/tmp/NutritionTracker.xcarchive \
     -allowProvisioningUpdates archive
   ```

3. Confirmar que el archivo contiene `Products/Applications/nutrition-tracker.app`, Info.plist con versión/build correctos, icono y manifest. Verificar firma con `codesign --verify --deep --strict` y entitlements con `codesign -d --entitlements :- RUTA_APP`; HealthKit debe seguir presente. El provisioning de **distribución** debe ser válido para el team y bundle; una instalación de desarrollo no lo demuestra.
4. En Organizer, generar/revisar **Privacy Report** y usar **Validate App**. Resolver errores de permisos, manifest, dependencias, icono, export compliance y signing. Revisar el `.app` efectivo antes de cambiar declaraciones. Apple describe el [manifest de privacidad](https://developer.apple.com/documentation/bundleresources/privacy_manifest_files) y las [APIs de razón obligatoria](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).
5. Crear o verificar la app correspondiente en App Store Connect. Publicar una política de privacidad accesible públicamente y completar App Privacy a partir del backend realmente habilitado. `docs/privacy.md` es una fuente editable; un archivo de un repo privado no satisface la URL pública requerida por [Apple](https://developer.apple.com/app-store/app-privacy-details/).
6. En Organizer, **Distribute App → App Store Connect → Upload**. Verificar procesamiento exitoso, versión/build y grupo de testers en TestFlight. Para testers externos, completar la revisión beta exigida por Apple.
7. Instalar **ese build** desde TestFlight, anotar versión/build y ejecutar la aceptación siguiente. Un upload procesado sin instalación no demuestra que el build sea instalable.

El archive `NutritionTrackerMVP-1.0-2.xcarchive` es de build 2 (8 de octubre) y queda como historial. El archive vigente, `/private/tmp/NutritionTrackerMVP-1.0-3.xcarchive`, se generó el 9 de octubre y pasó `ARCHIVE SUCCEEDED` y `codesign --verify --deep --strict`. Contiene versión 1.0/build 3, mínimo iOS 18, iPhone/iPad, icono, manifest, HealthKit y descripciones localizadas de cámara/Salud. Su perfil es **de desarrollo** (`get-task-allow=true`), no de distribución. La exportación de build 2 con `ios/Configuration/ExportOptions-AppStore.plist` y método `app-store-connect` falló por **No Accounts** y falta de perfil iOS App Store para el bundle; esto no se ha resuelto ni se ha subido build 3. `devicectl` instaló build 3 en el iPhone autorizado, pero no pudo abrirlo porque el dispositivo estaba bloqueado. No hay lanzamiento físico, upload ni instalación TestFlight acreditados. No se automatiza publicación ni se incluyen credenciales de App Store Connect en Git.

## Aceptación en dispositivo y accesibilidad

Registrar evidencia sin copiar salud personal a logs, capturas públicas o artefactos de CI. Para Salud, anotar tipos, rango, estado del flujo y resultado agregado de la prueba; no publicar valores personales.

| Área | Prueba y evidencia requerida | Estado de esta preparación |
|---|---|---|
| Instalación de desarrollo | Firma e instalación/launch en el iPhone autorizado | Build 3 se instaló con `devicectl`; launch pendiente porque el dispositivo estaba bloqueado |
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
