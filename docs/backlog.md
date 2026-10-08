# Nutrition Tracker iOS — alcance y backlog

Fecha: 8 de octubre de 2026. Repositorio: `peter7z/nutrition-tracker`.

## Objetivo y estado

App nativa iOS para registrar comidas por chat y fotos, visualizar calorías y macros y seguir peso y actividad. **Primera prioridad: NUT-01, importar los datos de Apple Health mediante HealthKit.** No depende de implementar chat ni servicios remotos.

El commit inicial prepara el proyecto SwiftUI, configuración iOS, esquema compartido, traducciones de la pantalla inicial y capability HealthKit. La importación y las otras funciones aún no están implementadas; ningún ticket se considera completado por crear el scaffold.

## Requisitos conservados

El backlog original revisó `seguimiento_calorias_peso.xlsx` versión 16 y requisitos de “Calorie tracking”, sin una transcripción íntegra. Esa fuente no se releyó en esta conversión; la evidencia original permanece en [backlog PWA archivado](archive/backlog-pwa-2026-10-05.md).

Conservar registro conversacional y correcciones, crudo/cocido, unidades, cantidad consumida y sobrantes, estimaciones visibles, objetivos versionados y cierre explícito del día. Cada entrada persiste antes de cerrar; medianoche no cierra automáticamente. Ausencia de datos no es cero. Un resumen histórico nunca fabrica comidas. Mantener importación de planilla sin escribir en el original, fotos/etiquetas, productos/recetas, preguntas y exportación/restauración.

## Arquitectura inicial

Monorepo: `ios/` contiene proyecto y fuentes iOS; `backend/` reserva el servicio futuro y `docs/` aloja contratos y planificación. Las validaciones deben ejecutarse por componente desde la raíz.

- SwiftUI nativo, iOS 18+, iPhone prioritario e iPad como destino soportado; UI accesible y localizada en español/inglés.
- HealthKit de lectura como primera integración; persistencia local y sincronización histórica/incremental. No se escribe en Salud ni se solicita background delivery en el scaffold.
- Persistencia, migraciones, backend y autenticación se concretan en NUT-02. No elegir proveedor ni contratar servicios por esta conversión.
- IA desde backend autenticado con secretos en servidor; app por HTTPS y credenciales en Keychain. Ninguna clave de IA en el binario.
- Procedencia por registro: Salud/manual/planilla/etiqueta/catálogo/estimación; snapshots nutricionales y metas versionadas. Reconcilación explícita evita dobles conteos.
- Zona horaria del perfil, inicialmente America/Montevideo; separar instante de registro y fecha del consumo. Nutrientes desconocidos son null, no cero.
- Datos de Salud locales por defecto. Cualquier envío a backend/IA requiere consentimiento específico, con contexto mínimo.

Entidades previstas: Profile, GoalVersion, DayLog, Meal, FoodEntry, FoodDefinition, WeightEntry, ActivityEntry, ChatMessage, Attachment, ChangeEvent, ImportBatch, HealthSample y HealthSyncCursor. La política de agregación separa comidas, totales históricos y energía activa.

## Orden de implementación

| Orden | Tickets | Resultado |
|---|---|---|
| 1 — máxima prioridad | 01 | Historial real de Apple Health, disponible localmente |
| 2 | 02 | Arquitectura, persistencia y acceso a servicios remotos |
| 3 | 03–06 | Registro confiable, cierre, Hoy e importación de planilla |
| 4 | 07–09 | Chat, correcciones y productos/recetas |
| 5 | 10–12 | Fotos, consultas y progreso con Salud + manual |
| 6 | 13–15 | Revisión, uso offline, TestFlight y recuperación |

P0: base necesaria; P1: completar MVP. S/M/L son tallas relativas. Cada PR verifica los criterios del ticket. Los números #1–#15 e identificadores NUT se conservan para mantener referencias; la definición original #1 se integra en #2 y #1 pasa a Apple Health. Estados actuales: abiertos.

## Tickets

### [NUT-01 — Importar datos de Apple Health con HealthKit (primera prioridad)](https://github.com/peter7z/nutrition-tracker/issues/1)

P0 · L · Orden de implementación: 1 · Dependencias: ninguna después del scaffold iOS.

Objetivo: levantar primero el historial de salud y actividad del usuario en la app nativa. La integración mínima funciona localmente antes del chat, la planilla y los servicios remotos.

## Criterios de aceptación

- [ ] Conectar Apple Health desde una pantalla SwiftUI mediante HealthKit; comprobar disponibilidad y solicitar únicamente permisos de lectura, por tipo, tras una explicación y acción explícita del usuario. Sin login ni backend como prerrequisito de esta primera entrega.
- [ ] Permitir elegir tipos y rango histórico: peso (bodyMass), pasos, energía activa y basal, tiempo de ejercicio y entrenamientos; energía ingerida, proteína, carbohidratos, grasa total y saturada cuando existan. No inferir comidas a partir de totales nutricionales.
- [ ] Importar el historial disponible con fecha/hora, unidad normalizada, UUID HealthKit, tipo y fuente/dispositivo; mostrar vista previa, cobertura temporal y última sincronización. Usar kg, kcal y gramos con conversiones verificadas y la zona horaria del perfil.
- [ ] Persistir localmente y sincronizar incrementalmente al abrir la app y al actualizar manualmente. Usar consultas ancladas para altas, cambios representados como reemplazos y eliminaciones; guardar cursor y datos en una misma operación recuperable. Un reintento o reinstalación con reimportación no duplica muestras.
- [ ] Para pasos y energía acumulada, usar estadísticas HealthKit con política documentada de agregación de fuentes; no sumar indiscriminadamente iPhone y Apple Watch. Energía de entrenamientos no se suma otra vez a la energía activa diaria. Conservar múltiples pesajes.
- [ ] Separar datos de Apple Health, manuales y de planilla. No contabilizar dos veces un registro del mismo evento ni sumar totales diarios importados sobre comidas ya existentes; presentar conflictos para elección explícita. Nunca rellenar faltantes con cero.
- [ ] No interpretar el éxito de requestAuthorization ni authorizationStatus como permiso de lectura concedido. HealthKit no revela una denegación de lectura: presentar “sin datos disponibles” cuando corresponda, manejar errores reales y permitir revisar permisos en Salud.
- [ ] La app no escribe ni borra en Apple Health en esta entrega. Desconectar detiene futuras consultas y ofrece borrar la copia local; no modifica el origen. Datos de salud quedan en el dispositivo y fuera de logs; cualquier envío futuro a backend o IA requiere consentimiento explícito y alcance mínimo.
- [ ] Verificar fixtures de conversiones, zona horaria, reintentos, fuentes superpuestas, borrados y falta de datos. Validar permisos e importación con datos reales en iPhone cuando se autorice esa prueba; el simulador no sustituye esa aceptación.

## Referencias

- [Autorización HealthKit](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data)
- [Consultas HealthKit](https://developer.apple.com/documentation/healthkit/queries)
- [Descripción del permiso de lectura](https://developer.apple.com/documentation/bundleresources/information-property-list/nshealthshareusagedescription)


### [NUT-02 — Consolidar arquitectura iOS, acceso privado y backend de desarrollo](https://github.com/peter7z/nutrition-tracker/issues/2)

P0 · M · Depende de: #1.

Objetivo: extender la base SwiftUI nativa para el registro nutricional y el chat. Las decisiones de arquitectura del antiguo NUT-01 se conservan aquí; el scaffold inicial no completa este ticket.

## Criterios de aceptación

- [ ] Monorepo con proyecto y fuentes Xcode en `ios/`, servidor futuro en `backend/` y documentación en `docs/`. Proyecto Xcode reproducible con esquema compartido, iOS 18 o superior, UI SwiftUI nativa y accesible, localización español/inglés y configuración Debug/Release. Wireframes de Hoy, Chat, Progreso y Ajustes con añadir, corregir y cerrar día.
- [ ] Documentar persistencia local (SwiftData o alternativa justificada), migraciones, fuente nutricional, API, backend, hosting, autenticación y presupuesto de IA; servicios remotos solo para funciones que los requieren. HealthKit sigue funcionando sin servidor.
- [ ] Definir contrato de datos y operaciones del asistente, objetivos versionados y diferencia entre planificación y consumo; separar datos HealthKit del tracking manual con procedencia y reconciliación explícita.
- [ ] Login y logout nativos funcionan para los servicios remotos; credenciales en Keychain y transporte HTTPS. Todas las rutas de datos exigen identidad autenticada; ningún secreto de OpenAI se incluye en el binario.
- [ ] Datos, fotos y consultas remotos se filtran por propietario; una prueba con dos identidades impide acceso cruzado. Logout separa o elimina la caché privada del usuario y evita mezcla de datos al cambiar de cuenta.
- [ ] Backend arranca con configuración documentada, migraciones reproducibles y entornos separados; despliegue de desarrollo verificable. Registrar permisos y consentimiento necesarios antes de enviar datos de salud fuera del dispositivo.

### [NUT-03 — Registro manual de alimentos y cálculo nutricional](https://github.com/peter7z/nutrition-tracker/issues/3)

P0 · M · Depende de: #2.

Objetivo: construir la fuente de verdad antes de introducir el chat.

## Criterios de aceptación

- [ ] Crear, editar y borrar alimentos de una comida con cantidad, unidad, estado crudo/cocido, fecha, nutrientes y procedencia.
- [ ] Soportar valores por 100 g, 100 ml o porción con conversión explícita; no asumir densidad universal.
- [ ] Totales por comida y día se calculan en código; nutrientes faltantes se identifican como desconocidos.
- [ ] Reintentos no duplican entradas; correcciones tienen versión y pueden deshacerse.
- [ ] Casos verificados: porción parcial, cambio de cantidad, saturadas desconocidas y etiqueta que no coincide exactamente con 4/4/9.

### [NUT-04 — Día abierto, cierre y correcciones históricas](https://github.com/peter7z/nutrition-tracker/issues/4)

P0 · S · Depende de: #3.

## Criterios de aceptación

- [ ] Las entradas del día abierto sobreviven al cierre y relanzamiento de la app; cierre solo mediante botón u orden explícita.
- [ ] Cerrar guarda un resumen versionado y estado de completitud; repetir cierre no duplica nada.
- [ ] Corregir un día cerrado exige reabrirlo explícitamente y conserva historial de cambios.
- [ ] “Hoy”, “ayer” y fecha explícita usan la zona horaria del usuario; pasar medianoche no cierra un día automáticamente.

### [NUT-05 — Pantalla Hoy nativa con calorías, macros y datos de Salud](https://github.com/peter7z/nutrition-tracker/issues/5)

P0 · M · Depende de: #3, #4.

## Criterios de aceptación

- [ ] Mostrar kcal, proteína, carbohidratos y grasas consumidas, objetivos y diferencia; saturadas como dato adicional cuando existan.
- [ ] Actualizar al registrar o corregir; mostrar detalle por comida y procedencia de estimaciones.
- [ ] Metas editables con fecha de vigencia; cambiar meta no altera registros anteriores.
- [ ] Estados vacío, cargando, error y día incompleto; interfaz legible en pantalla de teléfono y con lector de pantalla.
- [ ] Interfaz SwiftUI con Dynamic Type, VoiceOver y formatos locales; distinguir totales de ingesta de peso/actividad importados desde #1 y mostrar su fuente. Energía activa no aumenta automáticamente el presupuesto de comida.


### [NUT-06 — Importar historial de la planilla desde iOS sin inventar desglose](https://github.com/peter7z/nutrition-tracker/issues/6)

P0 · M · Depende de: #3, #4.

## Criterios de aceptación

- [ ] Previsualizar mapeo de Registro diario y Resumen antes de confirmar importación.
- [ ] Importar fechas, kcal, proteína, peso, actividad, notas y estado cerrado; filas futuras vacías se omiten.
- [ ] Carbohidratos/grasas solo se extraen de totales explícitos en notas, conservando procedencia; conflictos se señalan para revisión.
- [ ] Guardar los totales diarios originales como resumen histórico; no fabricar comidas ni volver a sumarlas sobre esos totales.
- [ ] Importación idempotente por archivo/lote y fecha; deshacer lote sin borrar datos creados después.
- [ ] Comparación por fecha contra fuente, informe de faltantes y registro de divergencias. No escribir en la planilla original.
- [ ] Selección de archivo mediante fileImporter/document picker de iOS, acceso limitado al archivo elegido y procesamiento con errores visibles. La migración de planilla es independiente de la importación de Apple Health #1; reconciliar coincidencias de peso/actividad sin duplicar.


### [NUT-07 — Integrar chat de consultas con contexto persistente](https://github.com/peter7z/nutrition-tracker/issues/7)

P0 · M · Depende de: #2, #3, #5.

## Criterios de aceptación

- [ ] API de OpenAI consumida desde backend, con modelo configurable, límite de gasto, límites por usuario y manejo de timeout.
- [ ] Contexto incluye objetivos, preferencias, día seleccionado y totales consultados desde la base; no depende de reenviar todo el historial.
- [ ] Mensajes persisten; respuesta no inventa que guardó datos si no hubo operación exitosa.
- [ ] Respuestas de tracking terminan con kcal y macros acumulados; consultas funcionan sin modificar ingesta.
- [ ] Registrar latencia, tokens/costo estimado y errores sin exponer fotos o contenido sensible en logs.
- [ ] Chat SwiftUI con historial y borrador persistentes, cancelación/reintento explícitos y estado de red. No enviar datos de HealthKit a la IA sin consentimiento específico; usar solo el contexto mínimo consentido.


### [NUT-08 — Registrar y corregir comidas conversacionalmente](https://github.com/peter7z/nutrition-tracker/issues/8)

P0 · L · Depende de: #7, #4.

## Criterios de aceptación

- [ ] Operaciones tipadas para añadir, actualizar, eliminar, consultar y cerrar; autorización y validación del lado servidor.
- [ ] “Anotá 150 g de banana” crea una entrada; “eran 100 g” actualiza esa entrada sin sumar otra.
- [ ] “¿Y si como una banana?” y “¿qué ceno?” no registran consumo.
- [ ] Pregunta cuando haya varias entradas candidatas o una unidad materialmente ambigua; permite deshacer una acción.
- [ ] Mensaje repetido, reintento de herramienta y desconexión durante respuesta no duplican registros; conflicto entre sesiones o dispositivos se detecta.
- [ ] El chat y la pantalla Hoy muestran los mismos totales luego de cada operación.
- [ ] Refrescar el estado observable de SwiftUI tras cada operación exitosa; deshacer y mostrar errores sin afirmar que una mutación fallida se guardó.


### [NUT-09 — Guardar productos frecuentes, etiquetas y recetas](https://github.com/peter7z/nutrition-tracker/issues/9)

P1 · M · Depende de: #3, #8.

## Criterios de aceptación

- [ ] Guardar productos con nombre/marca, porción y nutrientes, y seleccionarlos al mencionarlos otra vez.
- [ ] Priorizar etiqueta confirmada sobre estimación genérica; si la marca o versión es ambigua, pedir elección.
- [ ] Receta con ingredientes, peso total final o porciones y cantidad consumida; sobrantes no se contabilizan como consumidos.
- [ ] Editar producto cambia futuras entradas; aplicar a registros existentes requiere acción explícita.

### [NUT-10 — Estimar comidas y leer etiquetas con cámara y PhotosPicker](https://github.com/peter7z/nutrition-tracker/issues/10)

P1 · L · Depende de: #7, #8, #9.

## Criterios de aceptación

- [ ] Capturar con cámara nativa o elegir imágenes con PhotosPicker; permiso de cámara contextual y descripción localizada, sin solicitar acceso general a la fototeca para el picker. Validar tipo/tamaño y convertir HEIC u otros formatos soportados antes del análisis.
- [ ] Devolver componentes editables, cantidad estimada, kcal/macros y supuestos; no presentar gramos deducidos visualmente como medición.
- [ ] Pedir peso o aclaración cuando sea necesario; estimación visual se confirma antes de registrar.
- [ ] Etiqueta: distinguir porción de 100 g/ml, transcribir valores y señalar texto ilegible; usuario confirma antes de guardar producto.
- [ ] Adjuntos privados, metadatos de ubicación eliminados y acción de borrar foto; reintentar análisis no duplica comida.

### [NUT-11 — Recomendar comidas según el día y responder preguntas](https://github.com/peter7z/nutrition-tracker/issues/11)

P1 · M · Depende de: #7, #9.

## Criterios de aceptación

- [ ] “Tengo pollo y boniato, ¿qué ceno?” produce opciones con cantidades, kcal/macros estimados y total diario proyectado.
- [ ] Usar objetivos, preferencias y comida ya registrada; distinguir proyección de acumulado real.
- [ ] Registrar solo tras indicar qué se comió; permitir cambios como “usé menos aceite”.
- [ ] Explicitar límites de estimaciones y no diagnosticar ni prescribir fármacos; afirmaciones clínicas requieren fuentes verificables o expresar incertidumbre.

### [NUT-12 — Unificar peso y ejercicio de Apple Health y registros manuales](https://github.com/peter7z/nutrition-tracker/issues/12)

P1 · M · Depende de: #1, #3, #5, #8.

## Criterios de aceptación

- [ ] Peso con fecha/hora y actividad con tipo, duración y calorías activas opcionales, por formulario y chat.
- [ ] Múltiples pesajes al día conservados; regla visible para elegir el pesaje diario de la tendencia.
- [ ] Media móvil de 7 días calculada sobre observaciones disponibles con número de muestras visible; no rellenar faltantes con cero.
- [ ] Ejercicio se muestra separado y no aumenta automáticamente el presupuesto de comida.
- [ ] Gráficos con selección de rango, historial editable y estados de datos insuficientes.
- [ ] Swift Charts y listas accesibles con procedencia HealthKit/manual/planilla, cobertura y última sincronización. Las muestras de Salud se revisan en Salud; editar/borrar en la app no altera su origen. Reconciliar registros manuales y de planilla coincidentes antes de incluirlos en tendencias.


### [NUT-13 — Revisión semanal y propuestas de ajuste](https://github.com/peter7z/nutrition-tracker/issues/13)

P1 · M · Depende de: #11, #12, #4.

## Criterios de aceptación

- [ ] Resumen de ingesta, registro completo/incompleto, proteína, peso y actividad con cobertura de datos visible.
- [ ] Antes de recomendar ajustes, revisar suficiencia de pesajes y días completos durante dos semanas; parámetros se definen y documentan, no se infieren de una fluctuación diaria.
- [ ] Diferenciar observaciones calculadas de explicación del asistente; explicar datos usados y limitaciones.
- [ ] Objetivos solo cambian tras aceptación; conservar versión previa. Revisión bajo demanda, sin notificaciones programadas en esta entrega.
- [ ] La revisión usa los datos de Salud consentidos y distingue cobertura real de ausencia de datos; UI SwiftUI accesible para aceptar o rechazar cambios.


### [NUT-14 — Validar app iOS, uso sin conexión y distribución TestFlight](https://github.com/peter7z/nutrition-tracker/issues/14)

P1 · M · Depende de: #1, #5, #8, #10, #12.

Objetivo: reemplazar instalación PWA y service worker por instalación y ciclo de vida nativos de iOS.

## Criterios de aceptación

- [ ] Icono de app, nombre, bundle ID y versiones definitivos; firma, capability HealthKit y perfiles de distribución verificados. Archivo Release y build TestFlight instalable; revisar descripciones de permisos, política de privacidad y declaraciones de datos/dependencias exigidas al distribuir.
- [ ] Probar instalación, sesión persistente, permisos de Salud y cámara, PhotosPicker, teclado, safe areas, navegación, Dynamic Type, VoiceOver, modo claro/oscuro y tamaños iPhone; verificar layout iPad si se mantiene ese destino.
- [ ] Sin red: indicador explícito, lectura de registros persistidos y borrador local; HealthKit local disponible según permisos. IA requiere conexión; registrar operaciones pendientes sin afirmar que fueron sincronizadas.
- [ ] Al recuperar red, reenvío explícito e idempotente de borradores; logout elimina/separa caché privada y credenciales. Probar suspensión, terminación, relanzamiento y conflictos entre sesiones.
- [ ] Actualizar la versión no pierde datos ni conversaciones; probar migración de persistencia local y recuperación tras fallo. Sincronizar Salud al volver a primer plano; la entrega en segundo plano no se promete en el MVP.
- [ ] Validación rutinaria en Simulator; aceptación final de HealthKit con datos reales en iPhone y pruebas de distribución documentadas. No considerar firmado o publicado un build compilado con CODE_SIGNING_ALLOWED=NO.

### [NUT-15 — Exportación, recuperación y validación del MVP](https://github.com/peter7z/nutrition-tracker/issues/15)

P1 · M · Depende de: #1, #6, #8, #10, #11, #12, #13, #14.

## Criterios de aceptación

- [ ] Exportar datos estructurados a JSON/CSV con unidades, fechas, fuentes y notas; procedimiento de backup y restauración probado.
- [ ] Borrado de cuenta/datos incluye adjuntos y explica retención de backups configurada.
- [ ] Verificar flujo completo: conectar Apple Health e importar Salud y planilla, añadir comida, corregir, analizar foto, consultar cena, registrar peso/actividad, cerrar día y revisar progreso.
- [ ] Evaluación con frases representativas y resultados esperados; errores críticos: duplicar, registrar hipótesis, confundir crudo/cocido, fechar mal o exponer otro usuario.
- [ ] Revisar costos y latencias observados en uso personal antes de habilitar más usuarios.
- [ ] Exportar mediante share sheet de iOS y restaurar mediante document picker. Exportación de copia HealthKit es explícita; borrado de la app/cuenta incluye la copia local y cursores, sin borrar datos originales de Salud. Restaurar y reimportar Salud no duplica registros.


## Fuera de esta primera versión

Escritura en Apple Health, sincronización HealthKit garantizada en segundo plano, app Apple Watch, voz propia, códigos de barras, pagos, red social, administración multiusuario, IA offline y sincronización bidireccional con Excel. Apple Health **sí** integra el MVP y es la primera tarea.
