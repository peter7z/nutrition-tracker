# Nutrition Tracker — backlog companion iOS + plugin ChatGPT

Fecha: **10 de octubre de 2026**. Repositorio: `peter7z/nutrition-tracker`.

## Alcance vigente

La [especificación de producto](product.md) define el enfoque vigente: **iOS sincroniza Apple Health y muestra datos, historial y gráficas; el registro y las correcciones se hacen desde ChatGPT mediante un plugin**. El plugin incluye MCP e instrucciones/skills; eventualmente renderizará widgets con **ChatGPT Extensions**. No estamos construyendo solamente un servidor MCP ni otro chat dentro de iOS.

Sin registro manual/conversacional de tracking en iOS, cámara propia para comida, catálogo de alimentos ni carga manual de macros. ChatGPT estima nutrientes; el backend valida, persiste y calcula totales; iOS consulta. La escritura técnica para sincronizar Salud y la configuración de cuenta/consentimiento no habilitan edición de tracking en la app.

**Apple Health sigue como primera y máxima prioridad, NUT-01.** La app requiere iniciar sesión; con una sesión vigente, su lectura local funciona sin conexión al backend. Compartir datos con backend/plugin requiere un consentimiento adicional definido en NUT-18.

## Estado y migración

Se reformularon NUT-01 a NUT-15 conservando sus números y se agregaron NUT-16 a NUT-21. NUT-09 se retira y cierra como no planificado; NUT-21 sigue como roadmap posterior al MVP. NUT-07 está completado: retira funcionalidades y preserva datos, independientemente de la API futura. Los demás tickets siguen abiertos; el código anterior no acredita su aceptación.

La limpieza de NUT-07 retira chat, editores, catálogo, cámara, importación/restauración y el cliente de mutaciones de iOS. Mantiene lectura del historial y Salud local. NUT-02/NUT-15/NUT-19 migrarán los datos al nuevo sistema. El peso de Apple Health se enviará al servidor mediante NUT-18; ese transporte sigue pendiente.

Antecedentes: [backlog iOS con chat archivado](archive/backlog-ios-chat-2026-10-09.md), [snapshot de issues anterior al pivot](archive/issues-ios-chat-2026-10-10.json), [backlog PWA original](archive/backlog-pwa-2026-10-05.md). Las capturas actuales documentan la implementación anterior, no el nuevo diseño.

## Orden de entrega

| Etapa | Tickets | Resultado |
|---|---|---|
| 1 — máxima prioridad | 01 | Historial local de Apple Health y permisos reales |
| 2 | 02, 03, 16, 17 | Backend común, identidad y herramientas MCP |
| 3 | 08, 18, 19, 20 | Plugin conectado, registro desde ChatGPT, Salud consentida y lectura iOS |
| Limpieza inmediata | 07 | Retirada de funciones, sin agregar integraciones |
| 4 | 05, 12 | Dashboards y gráficas de consulta |
| 5 | 04, 06, 10, 11, 13 | Cierre, migración histórica, imágenes y consultas/revisión desde plugin |
| 6 | 14, 15 | Distribución, recuperación y aceptación integral |
| Posterior al MVP | 21 | Widgets con ChatGPT Extensions |
| Retirado, no planificado | 09 | Catálogo/recetas sin tarea activa |

P0 forma la base del nuevo producto; P1 completa y valida sus flujos; P2 no bloquea el MVP. Las dependencias de cada ticket determinan el orden dentro de una etapa. La aceptación del plugin requiere una conversación real de ChatGPT, además de pruebas de MCP Inspector; la de Salud requiere iPhone real.

## Tickets

### [NUT-01 — Importar Apple Health con HealthKit (primera prioridad)](https://github.com/peter7z/nutrition-tracker/issues/1)

P0 · ios,healthkit · Dependencias: ninguna.

La app importa datos existentes de Salud y permite consultarlos localmente. La app exige una sesión vigente; la lectura local no depende de una conexión al backend.

Criterios de aceptación:

- [ ] Permisos de lectura contextuales por tipo y rango: peso, pasos, energía activa/basal, ejercicio/entrenamientos y nutrientes disponibles; no crear comidas desde totales ni escribir/borrar en Apple Health.
- [ ] Persistir muestras, procedencia, unidades normalizadas, zona horaria y cursores de forma atómica; importación incremental con altas/eliminaciones, reintentos idempotentes y cobertura/última sincronización visibles.
- [ ] Usar agregaciones HealthKit para evitar doble conteo de iPhone/Watch y entrenamientos; conservar pesajes y distinguir desconocido de cero. No interpretar autorización completada como lectura concedida.
- [ ] Desconectar detiene consultas y ofrece borrar la copia local sin alterar Salud. Validar conversiones, superposición, reimportación y permisos reales en iPhone. Compartir con backend requiere NUT-18 y consentimiento adicional.

### [NUT-02 — Arquitectura del monorepo: companion iOS + backend + plugin ChatGPT](https://github.com/peter7z/nutrition-tracker/issues/2)

P0 · ios,backend,plugin · Dependencias: NUT-01.

Separar explícitamente las responsabilidades y migrar la arquitectura anterior sin perder historial.

Criterios de aceptación:

- [ ] ios/ contiene HealthKit, caché, visualización y configuración; backend/ es la fuente persistente del tracking; plugin/ alojará manifiesto, instrucciones y futuras extensiones. El servidor MCP es una pieza del plugin.
- [ ] iOS no crea/edita comidas, peso, actividad, metas ni cierres. Solo puede importar/sincronizar Salud y realizar operaciones técnicas de cuenta/consentimiento. El tracking se modifica desde ChatGPT mediante el plugin.
- [ ] Conservar registros existentes, versiones, procedencia y recibos; migración recuperable, aislamiento por propietario y reconciliación sin duplicar resúmenes. Documentar cambios respecto de la implementación actual.
- [ ] Contrato de datos compartido entre MCP, API de lectura iOS y futuras vistas del plugin; autenticación consistente, HTTPS, migraciones y entornos reproducibles. No incluir claves de IA en iOS ni exigir Responses API para el flujo principal.

### [NUT-03 — Persistencia y cálculo nutricional en el backend](https://github.com/peter7z/nutrition-tracker/issues/3)

P0 · backend · Dependencias: NUT-02.

El backend conserva los registros creados desde ChatGPT y calcula los totales autoritativos.

Criterios de aceptación:

- [ ] Persistir comida, cantidad/unidad, preparación, instante y día local, nutrientes estimados/etiqueta, supuestos, fuente, propietario y versión; ChatGPT estima macros sin catálogo ni carga manual de cada nutriente por el usuario.
- [ ] Conversiones explícitas por 100 g/ml o porción; no asumir densidad ni equivalencia crudo/cocido. Calcular totales en código, mantener null para desconocidos y respetar kcal de etiqueta.
- [ ] Mutaciones atómicas, idempotencia por operación, control de versión, auditoría y deshacer con conflictos visibles. Múltiples registros similares no se deduplican como si fueran la misma ingesta.
- [ ] Pruebas de cantidades parciales, nutrientes faltantes, permisos de propietario, reintentos y correcciones; mismo snapshot/totales para plugin e iOS.

### [NUT-04 — Cerrar, reabrir y corregir días desde el plugin](https://github.com/peter7z/nutrition-tracker/issues/4)

P1 · backend,plugin · Dependencias: NUT-03, NUT-08.

Las acciones de cierre y corrección ocurren en ChatGPT; iOS refleja el estado.

Criterios de aceptación:

- [ ] Herramientas tipadas para cerrar/reabrir y consultar completitud; cierre explícito e idempotente, sin cierre automático a medianoche.
- [ ] Corrección de día cerrado requiere reapertura explícita y conserva historial, totales y metas congeladas/versionadas.
- [ ] Resolver hoy/ayer/fechas con zona horaria del usuario y devolver el día afectado; no asumir fecha de conversación como fecha de consumo.
- [ ] iOS solo muestra estado/completitud y resumen actualizado, sin botones de cierre, reapertura o edición.

### [NUT-05 — Pantalla Hoy de consulta: calorías, macros y Salud](https://github.com/peter7z/nutrition-tracker/issues/5)

P0 · ios,healthkit · Dependencias: NUT-01, NUT-19.

Hoy es un dashboard, no una pantalla de registro.

Criterios de aceptación:

- [ ] Mostrar kcal/macros, metas vigentes y diferencia, peso/actividad y procedencia; distinguir ingesta de energía activa y no aumentar automáticamente el presupuesto de comida.
- [ ] Selección de fecha, detalle de registros de solo lectura y estados vacío/error/cargando/incompleto; ausencia de datos no se representa como cero.
- [ ] Reflejar registros y correcciones del plugin tras actualización, con última sincronización y cobertura. Usar totales autoritativos del backend.
- [ ] Dynamic Type, VoiceOver y localización español/inglés. Sin CTA de agregar comida, chat propio, micrófono, formularios de tracking ni metas editables.

### [NUT-06 — Migrar la planilla histórica al backend mediante el plugin](https://github.com/peter7z/nutrition-tracker/issues/6)

P1 · backend,plugin · Dependencias: NUT-03, NUT-16, NUT-20.

Conservar la migración histórica, trasladándola fuera de iOS y sin hacerla requisito del primer flujo del plugin.

Criterios de aceptación:

- [ ] Importación preparada mediante ChatGPT/plugin con mapeo y preview de fechas, kcal, proteína, peso, actividad y completitud; no usar file picker de iOS para registrar tracking.
- [ ] Confirmación del lote antes de escribir, límites de tamaño/cantidad y errores visibles. Verificar mecanismo real de acceso a archivos del host; no asumir que MCP recibe adjuntos de ChatGPT automáticamente.
- [ ] Resumen histórico conserva totales originales y procedencia sin fabricar comidas; omitir filas futuras vacías y nutrientes no explícitos. Reconciliar contra Salud sin sumar fuentes superpuestas.
- [ ] Lotes idempotentes y reversibles sin borrar cambios posteriores; comparación por fecha y archivo original intacto. iOS solo visualiza el resultado.

### [NUT-07 — Retirar registro y funciones innecesarias de iOS](https://github.com/peter7z/nutrition-tracker/issues/7)

**Limpieza de iOS — 10 de octubre de 2026.**

Prioridad: P0. Área: ios. Dependencias: ninguna para retirar funcionalidades.

## Objetivo

Retirar de iOS las funcionalidades de registro del enfoque anterior. Esta tarea solo elimina y preserva la consulta existente; no implementa todavía el plugin, cuenta nueva, API de lectura ni subida de Salud.

## Criterios de aceptación

- [x] No quedan chat, cámara/PhotosPicker, propuestas de IA, catálogo/recetas, formularios de comidas/peso/actividad, edición de metas, cierre/reapertura, borrado/deshacer de tracking, importación de planillas ni restauración de backups en iOS.
- [x] Eliminar los módulos, cliente de chat/sync de mutaciones, permisos de cámara y excepción de red local que sostenían esos flujos. La app no crea registros, reproduce solicitudes pendientes ni envía tracking manual al servidor.
- [x] Mantener Hoy, Progreso, detalles del historial, selección de fecha/rango y configuración/sincronización local de Apple Health. Los conflictos se consultan sin elegir ni guardar fuentes desde iOS.
- [x] Conservar los archivos existentes y sus esquemas, historial por propietario, metas/snapshots cerrados, adjuntos y pendientes antiguos sin activarlos. Verificar lectura de versiones anteriores/corrupción sin reescritura y recorridos de consulta en Simulator.

## Límites y trabajo posterior

El peso procedente de Apple Health **sí se enviará al servidor**: NUT-18 implementa esa sincronización con consentimiento. NUT-17/NUT-19 implementan cuenta y lectura remota. La navegación futura de Datos y los dashboards se completan en NUT-05/NUT-12/NUT-19. El registro se hace en ChatGPT mediante el plugin, que aún no está entregado.

Documentación: `docs/product.md`, `docs/validation.md`, `docs/backlog.md`. Se conserva la planificación y evidencia anterior en `docs/archive/`.

## Validación

31 pruebas de lógica y 4 de interfaz pasadas en iPhone 17 Pro/iOS 26.5; Release iOS compila y su manifiesto pasa plutil. Las pruebas de UI incluyen español, claro/oscuro y Dynamic Type máximo. Datos de fixtures; no permisos reales ni envío de Salud al servidor. Evidencia en `docs/validation.md`.


### [NUT-08 — Herramientas del plugin para registrar y corregir tracking](https://github.com/peter7z/nutrition-tracker/issues/8)

P0 · backend,plugin,mcp · Dependencias: NUT-03, NUT-16, NUT-17.

ChatGPT interpreta el mensaje y estima nutrientes; las herramientas validan y persisten operaciones reales.

Criterios de aceptación:

- [ ] Tools tipadas de crear/actualizar/eliminar/deshacer comidas y registrar peso/actividad; validar nutrientes, cantidades, fecha, IDs y versión. Cambiar metas/cierres usa herramientas específicas, nunca argumentos arbitrarios.
- [ ] «Anotá 150 g de banana» crea; «eran 100 g» corrige la entrada identificada sin duplicar. Preguntar cuando el destino o la unidad sean materialmente ambiguos; no pedir al usuario que cargue macros.
- [ ] «¿Y si como una banana?» o «qué ceno» solo consulta/proyecta. Descripciones/annotations de lectura y escritura correctas; confirmar acciones sensibles y no afirmar guardado antes del recibo exitoso.
- [ ] Idempotencia y versiones impiden duplicados por reintento del host; errores/conflictos visibles. Devolver ID, versión, datos efectivamente guardados y totales autoritativos para ChatGPT e iOS.

### [NUT-09 — Productos y recetas (retirado, no planificado)](https://github.com/peter7z/nutrition-tracker/issues/9)

**Cambio de producto — 10 de octubre de 2026.** iOS es un companion de consulta y sincronización de Apple Health; el registro ocurre en ChatGPT mediante un plugin. MCP es una pieza del plugin; los widgets mediante ChatGPT Extensions son una fase posterior.

Prioridad: P2. Área: backend,plugin. Dependencias: sin dependencia activa.

## Objetivo

Retirado del backlog activo: no queremos base de alimentos ni recetas por ahora. Cierre como **no planificado**, no como funcionalidad implementada.

## Criterios de aceptación

- [ ] No catálogo de alimentos, búsqueda de productos, carga manual de macros ni guardado de recetas en la app o el plugin del MVP.
- [ ] Conservar registros históricos existentes sin exponer un nuevo flujo de catálogo; snapshots de comida no equivalen a una base de alimentos.
- [ ] Cualquier alcance futuro de productos/recetas requiere una nueva decisión explícita de producto. Este alcance se retira; cualquier propuesta futura debe ser un nuevo ticket autorizado.

## Documentación y estado

Especificación: `docs/product.md`; backlog: `docs/backlog.md` en `peter7z/nutrition-tracker`. La planificación anterior se conserva en `docs/archive/backlog-ios-chat-2026-10-09.md` y `docs/archive/issues-ios-chat-2026-10-10.json`. Los criterios siguen abiertos; la implementación previa no acredita este nuevo alcance.

## Referencias de implementación

- [Servidor MCP del plugin](https://developers.openai.com/plugins/build/mcp-server).
- [Autenticación OAuth](https://developers.openai.com/plugins/build/auth).
- [Conectar el plugin a ChatGPT](https://developers.openai.com/api/docs/guides/custom-mcp-server).
- [UI y extensiones del plugin](https://developers.openai.com/plugins/build/chatgpt-ui).

## Estado

Cerrado como no planificado durante la limpieza. Se conservan sus referencias y los datos históricos; no queda una tarea activa de catálogo.


### [NUT-10 — Fotos y etiquetas desde ChatGPT mediante el plugin](https://github.com/peter7z/nutrition-tracker/issues/10)

P1 · plugin,backend · Dependencias: NUT-08, NUT-20.

Usar las capacidades de imagen de ChatGPT para generar datos estructurados, sin cámara propia de iOS.

Criterios de aceptación:

- [ ] El usuario comparte la imagen en ChatGPT; el asistente estima/transcribe y muestra supuestos. Verificar disponibilidad en el host real; no asumir acceso automático del MCP a la foto.
- [ ] Cantidad visual se marca como estimación y se aclara cuando sea relevante; etiqueta distingue porción/100 g/ml y partes ilegibles. No crear catálogo ni guardar consumo solo por analizar una imagen.
- [ ] Registrar únicamente al indicar/confirmar consumo mediante NUT-08; backend valida el snapshot, fechas/unidades y deduplicación por operación.
- [ ] No almacenar fotos originales por defecto ni depender de upload/cámara/PhotosPicker de iOS; cualquier futura retención de imágenes requiere propósito, consentimiento y borrado definidos.

### [NUT-11 — Instrucciones del plugin para consultas y estimaciones](https://github.com/peter7z/nutrition-tracker/issues/11)

P1 · plugin · Dependencias: NUT-16, NUT-20.

La conversación y el razonamiento ocurren en ChatGPT, apoyados en herramientas y guías del plugin.

Criterios de aceptación:

- [ ] Instrucciones/skills del plugin explican cuándo leer datos, estimar macros, aclarar supuestos y escribir; usar resultados actuales del backend, no memoria de conversación como fuente autoritativa.
- [ ] Consultar objetivos, preferencias, registros y Salud consentida antes de responder sobre el día/progreso; contexto acotado por fechas y cobertura, sin reenviar todo el historial.
- [ ] Propuestas de cena muestran cantidades y macros estimados y total proyectado separado del registrado; no registrar una planificación como consumo.
- [ ] Manejar errores y datos insuficientes sin inventar guardado ni ceros. No implementar un segundo chat o motor de conversación Responses en el backend/iOS para este flujo.

### [NUT-12 — Gráficas de peso, actividad y nutrición de solo lectura](https://github.com/peter7z/nutrition-tracker/issues/12)

P0 · ios,healthkit · Dependencias: NUT-01, NUT-19.

Visualizar evolución con datos de Salud y registros creados desde el plugin.

Criterios de aceptación:

- [ ] Swift Charts con rangos y detalle: peso, media móvil de 7 días, kcal/macros y actividad; cantidad de muestras/cobertura visible y huecos sin inventar observaciones.
- [ ] Conservar múltiples pesajes y documentar selección diaria; fuentes Salud/plugin/planilla identificadas y superposición reconciliada sin doble conteo.
- [ ] Actividad separada de ingesta; las gráficas y listas no contienen controles para crear, corregir o borrar tracking.
- [ ] Mismas series y reglas de agregación que herramientas del plugin/futuros widgets. Validar zonas horarias, valores desconocidos, iPhone pequeño/iPad, VoiceOver y Dynamic Type.

### [NUT-13 — Revisión semanal en ChatGPT y metas versionadas por plugin](https://github.com/peter7z/nutrition-tracker/issues/13)

P1 · backend,plugin · Dependencias: NUT-04, NUT-11, NUT-16.

ChatGPT interpreta una revisión calculada; las metas cambian mediante una operación del plugin.

Criterios de aceptación:

- [ ] Tool de revisión devuelve ingesta, completitud, proteína, peso, actividad y cobertura real; solo datos de Salud autorizados y frescura visibles.
- [ ] Política documentada de suficiencia durante dos semanas; no proponer ajustes de metas a partir de una fluctuación aislada.
- [ ] Separar observaciones calculadas de explicación/propuesta del asistente; aceptación explícita y tool versionada con fecha de vigencia, conflicto y recibo.
- [ ] iOS muestra la revisión/datos y metas resultantes como consulta, sin formulario ni botones de aceptar/rechazar cambios de metas.

### [NUT-14 — Validar y distribuir el companion iOS de lectura](https://github.com/peter7z/nutrition-tracker/issues/14)

P1 · ios,healthkit · Dependencias: NUT-01, NUT-05, NUT-07, NUT-12, NUT-19.

Validar la nueva app, offline y TestFlight con su alcance reducido.

Criterios de aceptación:

- [ ] Instalación, identidad, firma, HealthKit, privacidad y build TestFlight real; retirar permisos de cámara/micrófono/IA que no corresponden al nuevo producto.
- [ ] Probar conexión HealthKit, consentimientos remotos, cuenta, sincronización, fechas/gráficas y detalles; ausencia de registro/chat propio verificada en navegación.
- [ ] Offline: HealthKit local y última caché disponibles, pendientes técnicos de sync/frescura explícitos; no cola de registros ni borradores de chat en iOS.
- [ ] Simulator iPhone SE/grande/iPad, claro/oscuro, Dynamic Type y VoiceOver; aceptación de HealthKit real en iPhone y documentación de distribución, sin confundir build unsigned con TestFlight.

### [NUT-15 — Recuperación, privacidad y aceptación del sistema completo](https://github.com/peter7z/nutrition-tracker/issues/15)

**Cambio de producto — 10 de octubre de 2026.** iOS es un companion de consulta y sincronización de Apple Health; el registro ocurre en ChatGPT mediante un plugin. MCP es una pieza del plugin; los widgets mediante ChatGPT Extensions son una fase posterior.

Prioridad: P1. Área: backend,plugin,ios. Dependencias: NUT-01, NUT-08, NUT-18, NUT-19, NUT-20.

## Objetivo

Validar ChatGPT/plugin ↔ backend ↔ iOS y recuperar datos existentes sin pérdida.

## Criterios de aceptación

- [ ] Flujo completo: importar Salud, autorizar copia remota, consultar desde ChatGPT, registrar/corregir una comida por plugin y ver el resultado en iOS; mismo usuario y mismos totales.
- [ ] Exportación JSON/CSV con fuentes/unidades/versiones y restauración administrativa o vía plugin; iOS no incluye exportación, importación ni restauración en esta etapa; esas operaciones quedan en backend/plugin.
- [ ] Borrado de cuenta/copia remota y revocación de acceso cubren datos, tokens, cachés y backups según política; nunca borrar Apple Health como efecto secundario.
- [ ] Migración de la app anterior preserva historial; pruebas de dos propietarios, reintentos, conflictos, caídas, hipótesis no registradas y Salud no autorizada; evidencia por componente, no aceptación inferida desde código existente.

## Documentación y estado

Especificación: `docs/product.md`; backlog: `docs/backlog.md` en `peter7z/nutrition-tracker`. La planificación anterior se conserva en `docs/archive/backlog-ios-chat-2026-10-09.md` y `docs/archive/issues-ios-chat-2026-10-10.json`. Los criterios siguen abiertos; la implementación previa no acredita este nuevo alcance.

## Referencias de implementación

- [Servidor MCP del plugin](https://developers.openai.com/plugins/build/mcp-server).
- [Autenticación OAuth](https://developers.openai.com/plugins/build/auth).
- [Conectar el plugin a ChatGPT](https://developers.openai.com/api/docs/guides/custom-mcp-server).
- [UI y extensiones del plugin](https://developers.openai.com/plugins/build/chatgpt-ui).


### [NUT-16 — Servidor MCP del plugin: lectura, esquemas y transporte](https://github.com/peter7z/nutrition-tracker/issues/16)

P0 · backend,plugin,mcp · Dependencias: NUT-02, NUT-03.

Exponer las capacidades del backend como herramientas MCP que forman parte del plugin de ChatGPT.

Criterios de aceptación:

- [ ] Endpoint /mcp con Streamable HTTP, inicialización, listado de herramientas y llamadas reales; SDK compatible con backend y versiones documentadas.
- [ ] Tools de lectura para perfil/metas, registros por fecha, resumen diario, series de progreso, revisión y estado/cobertura de Salud; paginación, límites y formatos estructurados compartidos con iOS/widgets.
- [ ] Separar lectura y escritura con esquemas/annotations; validar propietario desde identidad autenticada, no owner_id dado por el modelo. Ninguna consulta tiene efectos de tracking.
- [ ] Inspector y pruebas de contrato, entradas inválidas, errores, fechas/timezone y resultados reproducibles; desplegar endpoint accesible al host elegido sin afirmar que localhost es una integración de ChatGPT.

### [NUT-17 — Identidad compartida y OAuth del plugin ChatGPT](https://github.com/peter7z/nutrition-tracker/issues/17)

P0 · backend,plugin,mcp · Dependencias: NUT-02.

Vincular plugin e iOS a la misma cuenta y controlar qué datos/herramientas se autorizan.

Criterios de aceptación:

- [ ] OAuth 2.1/PKCE y discovery MCP de recurso protegido/servidor de autorización; registro/identificación de cliente compatible con el host real, redirecciones verificadas y secretos fuera del repo.
- [ ] Scopes separados para leer tracking, escribir tracking y leer Salud autorizada; identidad por token validado, issuer/audience/expiry/scope y aislamiento estricto de propietarios.
- [ ] Login iOS y vinculación ChatGPT resuelven el mismo propietario persistente sin asociar cuentas por texto del chat; revocación, expiración, logout y cambio de usuario probados.
- [ ] No trasladar permisos HealthKit al OAuth automáticamente. Acceso a Salud remota depende además del consentimiento activo NUT-18; no secretos compartidos pegados en conversaciones.

### [NUT-18 — Sincronizar Salud autorizada del iPhone al backend](https://github.com/peter7z/nutrition-tracker/issues/18)

**Cambio de producto — 10 de octubre de 2026.** iOS es un companion de consulta y sincronización de Apple Health; el registro ocurre en ChatGPT mediante un plugin. MCP es una pieza del plugin; los widgets mediante ChatGPT Extensions son una fase posterior.

Prioridad: P0. Área: ios,backend,healthkit. Dependencias: NUT-01, NUT-02, NUT-17.

## Objetivo

Enviar al servidor los datos seleccionados de Apple Health, **incluido el peso medido/importado**, para que sean consultables desde el plugin. No se registra peso manualmente desde iOS. La retirada del cliente antiguo no elimina esta responsabilidad; el transporte específico de Salud está pendiente.

## Criterios de aceptación

- [ ] Consentimiento separado de la lectura local: explicar envío, almacenamiento en backend y acceso desde ChatGPT; elegir tipos/rango, revisar payload y revocar sin impedir consulta local.
- [ ] Sincronizar pesajes individuales de Apple Health con ID, fecha, kg, fuente y propietario; conservar la serie para gráficas y consulta desde ChatGPT. Enviar solo métricas/observaciones normalizadas necesarias y agregados con fuente/cobertura/timezone/frescura; no volcar toda HealthKit, metadatos de dispositivos ni contenido no seleccionado.
- [ ] ID estable por observación y propietario, lotes/ack/cursor atómicos, incremental altas/correcciones/eliminaciones y reintentos offline; no doble conteo entre fuentes o totales. Sync en primer plano/manual, sin garantía de background.
- [ ] El backend expone solo la copia autorizada a herramientas con scope de Salud; revocar detiene futuras cargas y accesos, con opción de borrar esa copia sin eliminar tracking ni originales en Apple Health.

## Documentación y estado

Especificación: `docs/product.md`; backlog: `docs/backlog.md` en `peter7z/nutrition-tracker`. La planificación anterior se conserva en `docs/archive/backlog-ios-chat-2026-10-09.md` y `docs/archive/issues-ios-chat-2026-10-10.json`. Los criterios siguen abiertos; la implementación previa no acredita este nuevo alcance.

## Referencias de implementación

- [Servidor MCP del plugin](https://developers.openai.com/plugins/build/mcp-server).
- [Autenticación OAuth](https://developers.openai.com/plugins/build/auth).
- [Conectar el plugin a ChatGPT](https://developers.openai.com/api/docs/guides/custom-mcp-server).
- [UI y extensiones del plugin](https://developers.openai.com/plugins/build/chatgpt-ui).


### [NUT-19 — API de consulta y caché iOS del tracking creado por el plugin](https://github.com/peter7z/nutrition-tracker/issues/19)

**Cambio de producto — 10 de octubre de 2026.** iOS es un companion de consulta y sincronización de Apple Health; el registro ocurre en ChatGPT mediante un plugin. MCP es una pieza del plugin; los widgets mediante ChatGPT Extensions son una fase posterior.

Prioridad: P0. Área: ios,backend. Dependencias: NUT-02, NUT-03, NUT-17.

## Objetivo

Llevar a la app el mismo historial y totales que registra ChatGPT. Completar la navegación de Datos y la consulta remota sin reintroducir registro, chat, importación ni restauración en iOS.

## Criterios de aceptación

- [ ] API autenticada de lectura de perfil/metas, días/comidas, peso/actividad, series y estados; contrato compartido con MCP, sin acceso iOS a mutaciones de tracking.
- [ ] Actualizar al abrir/volver a primer plano y manualmente; cursores/versiones, paginación y borrados reflejados en caché de forma atómica sin editar estados remotos.
- [ ] Última actualización, offline, vacío/error y procedencia visibles; detectar cambio de propietario y separar/eliminar caché privada según política.
- [ ] Prueba plugin crea/corrige → backend devuelve recibo → iOS refresca y muestra una sola entrada/totales correctos; no depender de mensajes de conversación ni de operaciones locales de registro.

## Documentación y estado

Especificación: `docs/product.md`; backlog: `docs/backlog.md` en `peter7z/nutrition-tracker`. La planificación anterior se conserva en `docs/archive/backlog-ios-chat-2026-10-09.md` y `docs/archive/issues-ios-chat-2026-10-10.json`. Los criterios siguen abiertos; la implementación previa no acredita este nuevo alcance.

## Referencias de implementación

- [Servidor MCP del plugin](https://developers.openai.com/plugins/build/mcp-server).
- [Autenticación OAuth](https://developers.openai.com/plugins/build/auth).
- [Conectar el plugin a ChatGPT](https://developers.openai.com/api/docs/guides/custom-mcp-server).
- [UI y extensiones del plugin](https://developers.openai.com/plugins/build/chatgpt-ui).


### [NUT-20 — Empaquetar, conectar y probar el plugin de ChatGPT](https://github.com/peter7z/nutrition-tracker/issues/20)

P0 · plugin,mcp · Dependencias: NUT-16, NUT-17, NUT-08.

Entregar un plugin utilizable, no solamente un servidor MCP suelto.

Criterios de aceptación:

- [ ] Paquete del plugin con identidad/descripción, manifiestos y configuración MCP, instrucciones/skills, documentación de instalación y estructura plugin/ versionada en el monorepo.
- [ ] Conectar e instalar de forma privada en ChatGPT con cuenta/host compatibles verificados; probar discovery, OAuth, lectura y escritura desde una conversación real. No confundir Inspector con aceptación del plugin.
- [ ] Documentar surfaces/planes/permisos realmente probados (incluido móvil/voz si se pretende usarlos); no prometer compatibilidad ni publicación pública sin verificarla.
- [ ] Preparar contratos/resultados structuredContent y organización para futuras ChatGPT Extensions NUT-21. Publicación en catálogo, revisión y widgets no son requisitos para el primer plugin privado.

### [NUT-21 — Widgets del plugin con ChatGPT Extensions (fase posterior)](https://github.com/peter7z/nutrition-tracker/issues/21)

P2 · plugin,roadmap · Dependencias: NUT-05, NUT-12, NUT-16, NUT-20.

Renderizar calorías/macros, peso y evolución dentro de ChatGPT mediante extensiones/widgets del plugin.

Criterios de aceptación:

- [ ] Widgets de resumen diario kcal/macros/metas, peso con tendencia y progreso por rango; datos estructurados reales del backend con fuente, fecha, cobertura y última actualización.
- [ ] Recursos UI y metadatos de herramientas usando la API de extensiones vigente al implementar; misma capa de consulta/contratos que iOS, sin base paralela ni cálculo contradictorio.
- [ ] Renderizar o abrir un widget no registra consumo ni cambia metas; cualquier futura acción usa las herramientas autorizadas existentes y su política de confirmación.
- [ ] Diseño accesible, claro/oscuro, responsive, vacío/error/datos insuficientes, CSP/aislamiento y pruebas en el host real; validar disponibilidad antes de prometer soporte. Este ticket es roadmap y no bloquea el MVP sin widgets.

## Referencias técnicas

- [Servidor MCP como pieza del plugin](https://developers.openai.com/plugins/build/mcp-server).
- [Autenticación OAuth del plugin](https://developers.openai.com/plugins/build/auth).
- [Conexión con ChatGPT](https://developers.openai.com/api/docs/guides/custom-mcp-server).
- [UI y extensiones dentro de ChatGPT](https://developers.openai.com/plugins/build/chatgpt-ui).

Estas referencias guían los tickets; no prueban que la cuenta, el host móvil/voz, el deployment o los widgets estén disponibles/configurados. Verificar en la implementación real.

## Implementación inicial del plugin — 10 de octubre de 2026

NUT-16/NUT-17/NUT-20 avanzan con el paquete `plugin/`, skill de tracking,
MCP Streamable HTTP en `/mcp` y OAuth persistido (DCR, S256 PKCE, resource,
permisos lectura/escritura, vencimiento/rotación/revocación). NUT-08 entrega
`record_food`, `update_food`, `delete_food` con las validaciones existentes,
UUIDs de operación, revisiones/versiones y recibos. `get_profile`, `get_day`
y `get_progress` entregan consulta estructurada y totales del servidor.
ChatGPT estima la porción; las tools no invocan otro modelo ni un catálogo.

99 pruebas locales contra SQLite y Postgres verifican protocolo, OAuth,
aislamiento, permisos, idempotencia, correcciones/borrados y totales. No se
cierran los tickets por estas pruebas: falta aceptación desde una conversación
real en ChatGPT, importación del paquete y compatibilidad de superficies.
Además siguen pendientes peso/actividad por tools específicas, deshacer,
metas/cierres, scope y transporte de Salud, lectura iOS y widgets.


### Verificación pública — 10 de octubre de 2026

Render desplegó `a06d63fe9a9580392c8103f77020396b653cc9fc` mediante
`dep-db5f9kjbc2fs738ndggg`. [CI](https://github.com/peter7z/nutrition-tracker/actions/runs/38105072707)
aprobó backend (99 pruebas, SQLite/Postgres) e iOS. La prueba HTTP pública
verificó discovery, OAuth/PKCE, registro/corrección/borrado, totales, reintentos
idempotentes, aislamiento de cuentas/scopes y renovación/revocación. Las dos
cuentas sintéticas se eliminaron al terminar. Instalación y conversación real
en ChatGPT siguen pendientes; no se usaron datos reales de Salud.


## Sign in with Apple — 11 de octubre de 2026

NUT-17 incorpora login Apple nativo, sesión segura en Keychain, perfil/logout
y autorización web del plugin preparada para Services ID y key. Por decisión
del producto, la primera conexión une automáticamente la cuenta del mismo
email verificado por Apple; las posteriores usan su identidad estable.
121 pruebas backend SQLite/Postgres, 35 unitarias iOS y 4 UI aprobadas.
Configuración y aceptación pendientes: [Apple](apple-sign-in.md). No se cierra
NUT-17: faltan Apple real, revocación Apple y aceptación del sistema; NUT-19
sigue pendiente para lectura/caché remota y NUT-18 para envío de Salud.
