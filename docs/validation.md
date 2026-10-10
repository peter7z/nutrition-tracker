# Matriz de evidencia de aceptación

> **Cambio de producto — 10 de octubre de 2026:** este documento conserva implementación/evidencia del enfoque anterior. El alcance vigente se define en [especificación de producto](product.md) y el backlog: companion iOS de consulta/Salud, registro desde el plugin de ChatGPT y widgets futuros con Extensions. Sus referencias a chat, registro o edición en iOS no son requisitos vigentes. La adaptación del código y de los contratos está pendiente.

Estado de auditoría: 9 de octubre de 2026. Esta matriz relaciona **los 81 criterios de MVP vigentes** de [backlog.md](backlog.md) con código y pruebas observables; NUT-09 conserva cuatro criterios de referencia futura, diferidos y excluidos de esta cuenta. Los rótulos de la primera columna son resúmenes; cada ID apunta al criterio íntegro y con el mismo alcance que permanece en el backlog. “Implementado/test” significa que hay código y el XCTest pertinente está incluido en el último log integrado disponible; no significa aceptación del ticket. “Implementado” indica código revisado sin un test focalizado o una prueba de extremo a extremo. “Parcial” indica que falta una parte del comportamiento o una puerta de validación. Ninguna fila cierra un ticket.

## Evidencia global y límites

- `/private/tmp/nutrition-chat-first-unit.log`: **126 pruebas unitarias, 0 fallos**, `TEST SUCCEEDED`, 9 de octubre a las 15:42 local. El dominio permanece sin cambios desde esa corrida.
- `/private/tmp/nutrition-chat-first-final.log`: suite chat-first final de **5 UITests, 0 fallos**, `TEST SUCCEEDED`, 9 de octubre a las 16:09 local. Incluye registrar una propuesta sintética de 150 g/133.5 kcal, corregir a 100 g/89 kcal, conservar una sola entrada, cerrar, relanzar y reabrir; también borrador offline, no registrar antes de enviar y navegación española con Dynamic Type grande/oscuro y estándar/claro.
- `/private/tmp/nutrition-chat-first-ui.log` documenta una corrida de depuración anterior de 3/5 UITests; sus dos fallos se resolvieron antes del log final. El log `/private/tmp/nutrition-mvp-full-validation.log` de 120 unitarios y 5 UI pasados también es anterior al cambio chat-first. La captura visual oscura de esa etapa aparecía clara; la suite final pasa el caso oscuro, y las ocho capturas actuales de Hoy, Chat, Progreso y Ajustes se actualizaron desde esa corrida.
- `/private/tmp/nutrition-chat-first-ipad-screen.log`: **2 UITests, 0 fallos**, iPad Pro 13 (M5), claro estándar y oscuro con Dynamic Type máximo. Ambos recorren Hoy, Chat, Progreso y Ajustes; también verifican la ventana horizontal y capturan Hoy/Chat/Progreso. Se revisaron las capturas completas. No acredita cámara, archivos, share sheets, teclado con datos ni VoiceOver en iPad.
- `backend/README.md`: informa **46 pruebas Python** y smoke local con Responses/cliente nativo. También indica que no se probó Docker/Compose y que no hay endpoint público.
- Auditoría XLSX de solo lectura anotada en `backlog.md`: dos hojas detectadas; el parser nativo y la referencia coincidieron en las ocho filas activas y omitieron las 82 filas futuras vacías. Sin divergencias de fecha, calorías, proteína o peso. No se conservaron datos de celdas. Esto prueba parsing de ese archivo, no el flujo UI de importación ni el undo de un lote real.
- La evidencia integrada actual acredita 126 pruebas unitarias, 46 pruebas backend y 5 de 5 UITests. Los flujos de cámara, archivos y teclado con datos en iPad, VoiceOver, HealthKit real, importación completa y distribución siguen pendientes. La revisión visual de las capturas finales de estados vacíos se realizó; no sustituye la matriz de estados con datos, permisos y errores.

## NUT-01 — Apple Health

| Criterio | Estado y evidencia |
|---|---|
| 01.1 Conexión y permiso de lectura tras acción explícita | Implementado/test: `HealthViews.swift`, `HealthKitClient.swift`; `HealthSyncTests.testEmptyAuthorizationResultDoesNotInventPermissionOrData`. Falta permiso real en iPhone. |
| 01.2 Tipos, rango y no fabricar comidas | Implementado/test: `HealthModels.swift`, `HealthViews.swift`, `HealthKitClient.swift`; `HealthSyncTests` prueba selección, energía de comida y separación de entrenamiento. Falta contrastar tipos disponibles con Salud real. |
| 01.3 Muestras, metadatos, unidades, cobertura y última sync | Implementado/test: `HealthKitClient.swift`, `HealthViews.swift`, `HealthSyncModel.swift`; fixtures de conversión/cursor en `HealthSyncTests`. Preview y provenance real en dispositivo pendientes. |
| 01.4 Anclas, deltas, borrados y guardado recuperable/idempotente | Implementado/test: `HealthSyncModel.swift`, `HealthRepository.swift` (`HealthFileRepository`); tests de página, UUID, rollback, borrado y cursor. Reimportación después de reinstalar pendiente en equipo real. |
| 01.5 Agregados sin sumar fuentes y entrenamientos sin doble energía | Implementado/test: estadísticas HealthKit en `HealthKitClient.swift`; `HealthSyncTests.testMergedDailyTotalsAreUsedInsteadOfAddingOverlappingSources` y `testWorkoutAndActiveEnergyAreSeparateFromDietaryEnergy`. Fuentes personales pendientes. |
| 01.6 Separar Health/manual/planilla y resolver solapamientos | Implementado/test: `TrackingBridge.swift`, `TrackingProgressView.swift`, `ProgressAnalyticsTests`, `TrackingBridgeTests`. Falta comprobar el matching con fuentes reales de Salud y planilla juntas. |
| 01.7 No inferir permiso y mostrar ausencia/error | Implementado/test: `HealthKitClient.swift`, `HealthViews.swift`; fixture de autorización vacía y fallos en `HealthSyncTests`. Revocación real pendiente. |
| 01.8 Solo lectura, desconectar/borrar copia y privacidad | Implementado/test: `HealthSyncModel.swift`, `HealthViews.swift`, `HealthRepository.swift`; tests de desconexión/retención y `HealthNutritionClosureTests`. Falta verificar en iPhone que Salud original no cambie. |
| 01.9 Fixtures y aceptación con datos reales | Fixtures: `HealthSyncTests` y `HealthNutritionClosureTests` pasan en el log integrado. Permisos, importación, revocación y borrados de Salud real siguen pendientes. |

## NUT-02 — Arquitectura, autenticación y backend

| Criterio | Estado y evidencia |
|---|---|
| 02.1 Monorepo, proyecto reproducible, UI/locales y wireframes | Implementado: `ios/NutritionTracker.xcodeproj`, esquema compartido, catálogos y `docs/design/`. Los cinco UITests chat-first pasaron en `/private/tmp/nutrition-chat-first-final.log`. VoiceOver y matrices completas de UI siguen pendientes. |
| 02.2 Persistencia/migraciones/API/hosting/presupuesto documentados | Implementado/test parcial: `NutritionRepository.swift`, `NutritionMigrationTests.swift`, `backend/README.md`, `backend/app/config.py`, `docs/backend-contract.md`. Compose/despliegue y endpoint público no probados/configurados. |
| 02.3 Contratos, versiones, fuentes y consumo vs proyección | Implementado/test: `NutritionModels.swift`, `backend/app/models.py`, `backend/app/nutrition.py`, `docs/backend-contract.md`; `NutritionCoreTests`, `TrackingBridgeTests` y tests backend. |
| 02.4 Login/logout, Keychain, HTTPS y auth | Implementado/test: `AccountAccessView`/`RemoteSession.swift`, `backend/app/main.py`; `RemoteSessionTests` y pruebas backend de autenticación. No se ha verificado un deployment externo. |
| 02.5 Propiedad de datos y separación entre usuarios | Implementado/test: `TrackingSync.swift`, backend owner filtering; `TrackingSyncTests.testRemoteOnlyMergeAndTwoOwnerLateResponseCannotPublish`, `testExplicitConflictResolutionUsesServerAndSeparateOwnersUseSeparateJournals` y pruebas backend de aislamiento. Cambios de cuenta en producción pendientes. |
| 02.6 Arranque, migraciones, entorno y consentimiento | Parcial: API y migraciones locales están en `backend/`; README informa healthz y pruebas locales. Docker/Compose y despliegue no se ejecutaron; HTTPS público y permisos del operador pendientes. |

## NUT-03 — Diario nutricional interno y cálculo

| Criterio | Estado y evidencia |
|---|---|
| 03.1 Persistencia de comidas confirmadas desde Chat | Implementado/test: `NutritionStore.swift`, modelos y `TrackingSync.swift`; `NutritionCoreTests.testMutationIsAtomicRetryIdempotentAndUndoVersioned` y `TrackingSyncTests` de acuse y reintento. La entrada manual de macros no es requisito de MVP. |
| 03.2 Base 100 g/ml/porción y conversiones explícitas | Implementado/test: `NutritionModels.swift`, `NutritionStore.swift`; `NutritionCoreTests.testUnitsRequireExplicitDensityAndServingConversion`. |
| 03.3 Totales y nutrientes desconocidos | Implementado/test: `NutritionStore.swift`, `NutrientValuesRows` en `ContentView.swift`; `testMissingNutrientsAndRealZeroAreDifferent` y `testPartialPortionPreservesLabelCaloriesAndMissingSaturatedFat`. |
| 03.4 Reintentos, versiones y undo | Implementado/test: store operation receipts/versioning; `NutritionCoreTests.testMutationIsAtomicRetryIdempotentAndUndoVersioned`, `testUndoNeverOverwritesLaterCorrection`, `testOperationUUIDCannotBeReusedWithChangedBodyActionOrIdentity`. |
| 03.5 Casos parciales, saturadas y calorías de etiqueta | Implementado/test: `NutritionCoreTests.testPartialPortionPreservesLabelCaloriesAndMissingSaturatedFat`; `backend/tests/test_backend.py::test_density_unknown_nutrients_and_label_energy_not_449`. Etiquetas personales no evaluadas. |

## NUT-04 — Cierre y corrección histórica

| Criterio | Estado y evidencia |
|---|---|
| 04.1 Persistencia y cierre explícito | Implementado/test: `ContentView.swift`, `NutritionStore.swift`; `testExplicitCloseReopenAndRepeatedCloseKeepsVersionedSnapshots` y el UITest chat-first final pasaron. El UI test cierra, relanza y reabre la entrada. |
| 04.2 Snapshot versionado/completitud y cierre repetido idempotente | Implementado/test: `NutritionStore.swift`, `NutritionCoreTests.testExplicitCloseReopenAndRepeatedCloseKeepsVersionedSnapshots`. |
| 04.3 Reabrir antes de corregir y conservar historial | Implementado/test: `NutritionCoreTests.testExplicitCloseReopenAndRepeatedCloseKeepsVersionedSnapshots`, `TrackingSyncTests.testOfflineReopenCorrectionRecloseSendsIntermediateOpenInOrder` y el recorrido chat/corrección/cierre/reapertura del UITest final. |
| 04.4 Fechas en zona de perfil y no cerrar a medianoche | Implementado/test: calendario de perfil en `NutritionModels.swift`; `NutritionCoreTests.testTimezoneMidnightDoesNotCloseAndRecordsPersist`. Falta revisar UX de zona en dispositivo. |

## NUT-05 — Hoy

| Criterio | Estado y evidencia |
|---|---|
| 05.1 Ingesta, metas, diferencias y saturadas | Implementado: `ContentView.swift`, `NutritionStore.swift`, `HealthViews.swift`; cálculos en `NutritionCoreTests`. Layout final/VoiceOver pendientes. |
| 05.2 Actualizar, detalle por comida y procedencia | Implementado/test: `ContentView.swift`, `NutritionModels.swift`, `NutritionCoreTests` y UITest chat-first final: la corrección por Chat deja una sola entrada y actualiza sus nutrientes. |
| 05.3 Metas con fecha sin reescribir históricos | Implementado/test: `AppSettingsView.swift`, `NutritionStore.swift`; `NutritionCoreTests.testGoalsEffectiveByDateAndPauseDoesNotRewriteHistory`, `testClosedGoalsStayFrozenAfterBackdatedGoalChangeAndUnspecifiedGoalsRemainNil`. |
| 05.4 Estados y legibilidad móvil/lector | Implementado parcialmente: estados en `ContentView.swift`; render y recorridos nativos incluidos en los cinco UITests pasados. VoiceOver y revisión completa de errores/carga siguen pendientes. |
| 05.5 Dynamic Type/locales, separación y fuentes | Implementado/test: `ContentView.swift`/`Localizable.xcstrings`; navegación española con Dynamic Type grande/oscuro y estándar/claro pasó en la suite final. VoiceOver y revisión visual de todas las pantallas pendientes. |

## NUT-06 — Importación de planillas

| Criterio | Estado y evidencia |
|---|---|
| 06.1 Selección de Registro/Resumen y preview del mapeo | Implementado: `SpreadsheetImportView.swift`, `SpreadsheetReader.swift`; fixtures `SpreadsheetReaderTests`. El audit real leyó dos hojas, pero no ejercitó selección/confirmación del picker. |
| 06.2 Fechas, kcal/proteína, peso, actividad, notas/cierre y filas vacías | Implementado/test: `SpreadsheetPreviewBuilder`, `NutritionStore.importBatch`; fixtures CSV/XLSX. Audit real contrastó fecha, kcal, proteína y peso; actividad/notas/cierre solo tienen fixtures, no contraste real. |
| 06.3 Extraer solo macros explícitos de notas y resolver conflictos | Implementado/test: `SpreadsheetReader.swift`, `SpreadsheetReaderTests.testPreviewMapsExplicitNutritionFlagsConflictsAndFutureEmptyRows`. No se afirma cobertura de macros en el XLSX auditado. |
| 06.4 Resúmenes históricos sin fabricar comida ni duplicar totales | Implementado/test: `NutritionStore.swift`, `TrackingBridge.swift`; `NutritionCoreTests.testHistoricalImportIdempotentConflictExplicitAndUndoKeepsLaterRecords`, `testClosedHistoricalSourceFreezesOriginalTotalsWithoutInventingFoodEntries`. |
| 06.5 Idempotencia por lote/fecha y undo sin borrar cambios posteriores | Implementado/test: `NutritionCoreTests.testHistoricalImportIdempotentConflictExplicitAndUndoKeepsLaterRecords`, `testImportUndoRestoresPriorChoiceButPreservesLaterDecisionEvenSameSelection`, `TrackingSyncTests.testLargeImportBatchesPersistRetryIDsAndPublishOnlyAfterAllAcks`. Sin importación real confirmada. |
| 06.6 Comparación/faltantes/divergencias y original intacto | Parsing probado contra el original: 8 filas activas, 82 futuras vacías omitidas, 0 divergencias de fecha/kcal/proteína/peso; detalle resumido en `backlog.md`. El reporte UI y la escritura cero se infieren del diseño read-only; la importación manual real no se ejecutó. |
| 06.7 Document picker, acceso limitado y errores | Implementado: `SpreadsheetImportView.swift` usa `fileImporter` y acceso de archivo acotado. `SpreadsheetReaderTests` prueba errores del parser; flujo UI de seleccionar/confirmar/undo en dispositivo pendiente. |

## NUT-07 — Chat y contexto

| Criterio | Estado y evidencia |
|---|---|
| 07.1 OpenAI solo desde servidor, modelo/costos/límites/timeout | Implementado/test: `backend/app/assistant.py`, `backend/app/config.py`, `backend/app/main.py`; pruebas backend y smoke real descrito en `backend/README.md`. Sigue pendiente configurar endpoint/secretos de un entorno de uso. |
| 07.2 Contexto del propietario con metas, preferencias y día | Implementado/test: `backend/app/nutrition.py::context_for`, `backend/app/main.py`; backend verifica aislamiento/contexto. No se reenvía historia completa. |
| 07.3 Historial persistente y no afirmar guardado sin ack | Implementado/test: `AssistantChatView.swift`, `TrackingSync.swift`, `backend/app/main.py`; `TrackingSyncTests.testUnansweredRemoteUserHasFailedOutboxWithoutInventedAssistant`, `NutritionChatIdentityTests.testNativeAssistantUsesRequestIdentityAndHydratedResponseDoesNotDuplicate`, `AssistantRequestRecoveryTests`. |
| 07.4 Totales determinísticos y consultas sin modificar ingesta | Implementado/test: `backend/app/nutrition.py`, `backend/app/main.py`, `assistant.py`; `backend/tests/test_backend.py::test_chat_proposals_no_write_idempotent_and_owned_context`, tests de hipótesis; smoke Responses documentado. |
| 07.5 Métricas y logs sin texto/fotos/datos sensibles | Implementado por código/documentación: logger de `backend/app/main.py`, `backend/README.md`, `docs/privacy.md`; smoke registra costo/latencia estimados. Revisión externa/auditoría de logs en hosting no existe. |
| 07.6 UI persistente, borrador, cancelar/reintentar, red y Health consentido | Implementado/test parcial: `AssistantChatView.swift`, `RemoteSession.swift`, `NutritionChatIdentityTests`, `TrackingSyncTests`; UITest offline y no-guardar-antes-de-enviar pasaron. La transición real de red sigue pendiente. |

## NUT-08 — Mutaciones conversacionales

| Criterio | Estado y evidencia |
|---|---|
| 08.1 Operaciones tipadas y validación de servidor | Implementado/test: `backend/app/models.py`, `backend/app/main.py`, `assistant.py`; `backend/tests/test_backend.py`, suite reportada por backend README. |
| 08.2 Añadir explícito y corregir la misma entrada | Implementado; fixtures backend para add/correction y smoke Responses consumido/corregido según `backend/README.md`. Sin evaluación amplia con frases de uso personal. |
| 08.3 Hipótesis/cena sin registrar | Implementado/test: `backend/app/assistant.py::guard_output`; `test_hypothetical_text_cannot_mutate_even_if_provider_misclassifies` y smoke de cena. |
| 08.4 Ambigüedad pide aclaración; undo | Implementado/test: guard de versiones/candidatos; `test_ambiguous_correction_invalid_entry_or_version_requires_clarification`, `NutritionCoreTests.testUndoNeverOverwritesLaterCorrection`. |
| 08.5 Reintentos sin duplicar, desconexión y conflictos | Implementado/test: `TrackingSyncTests`, `AssistantRequestRecoveryTests`, `NutritionCoreTests.testOperationUUIDCannotBeReusedWithChangedBodyActionOrIdentity`; conflictos concurrentes probados con dobles de red/servidor. |
| 08.6 Coincidencia de totales Chat/Hoy | Implementado/test: backend deriva totales, `TrackingBridgeTests`, `NutritionCoreTests`; el UITest final registró, corrigió y confirmó la única entrada visible en Hoy. |
| 08.7 Refresh tras ack, undo y error veraz | Implementado/test: `TrackingSync.swift`, `AssistantChatView.swift`; `TrackingSyncTests.testAssistantMutationIsUnpublishedUntilAcknowledgedAndSaveFailureRetriesJournal`, failed outbox y UITest offline/confirmación pasaron. Una transición de red física sigue pendiente. |

## NUT-09 — Productos y recetas (diferido)

| Criterio | Estado y evidencia |
|---|---|
| Referencia futura (09.1–09.4) | Diferido fuera del MVP por decisión de producto. Aunque hay código de biblioteca y sus pruebas, no se exige catálogo, guardado de producto/receta ni reuso en el flujo principal. Los cuatro criterios se conservan sin contar en los 81 criterios de MVP vigentes. |

## NUT-10 — Cámara, foto y etiqueta

| Criterio | Estado y evidencia |
|---|---|
| 10.1 Cámara/PhotosPicker, permiso y conversión/validación | Implementado/test parcial: `AssistantChatView.swift`, `InfoPlist.xcstrings`, `RemoteSession.swift`, `AttachmentFiles`; tests de validación/borrado. Cámara, PhotosPicker, permiso y HEIC requieren iPhone real. |
| 10.2 Propuesta editable con estimaciones y supuestos | Implementado: `AssistantChatView.swift`, `AssistantObservationReview.swift`, `backend/app/assistant.py`; backend smoke sintético de etiqueta/foto documentado. Exactitud y legibilidad con imágenes reales pendientes; confirmación crea snapshot de la comida, no producto de catálogo. |
| 10.3 Peso/aclaración y confirmación antes de guardar | Implementado/test: `AssistantChatView.swift`, `assistant.py::guard_output`; pruebas backend de aclaración y proposals sin write, `AssistantObservationReviewTests`. UI de foto pendiente. |
| 10.4 Base 100g/ml/porción, ilegibles y confirmación | Implementado, smoke sintético: instrucciones/validación en `backend/app/assistant.py`, schema en `backend/app/models.py`; rerun sintético de etiqueta descrito en `backend/README.md`. OCR/lectura real no aceptada. Confirmar la etiqueta guarda sus nutrientes con la comida; guardar producto queda diferido. |
| 10.5 Privacidad, borrado, metadata y reintento | Implementado/test: attachment owner routes en `backend/app/main.py`, sanitización en `AttachmentFiles`, `AttachmentRemovalTests`, `TrackingBackupTests`. No se ha validado cámara o borrado en dispositivo. |

## NUT-11 — Consultas y recomendaciones

| Criterio | Estado y evidencia |
|---|---|
| 11.1 Opciones de cena con cantidades, macros y proyección | Implementado; smoke Responses real de cena con fixture según `backend/README.md`; la recomendación no se registra automáticamente. Más casos y validación con preferencias reales pendientes. |
| 11.2 Metas/preferencias/ingesta y separar proyección | Implementado/test: `backend/app/nutrition.py`, `assistant.py`; tests de contexto y no mutación, smoke de cena. |
| 11.3 Registrar solo con intención explícita y corregir | Implementado/test: `guard_output`, `backend/tests/test_backend.py::test_hypothetical_text_cannot_mutate_even_if_provider_misclassifies`, pruebas de correction/add; revisión amplia pendiente. |
| 11.4 Incertidumbre y límites clínicos | Instrucciones de seguridad implementadas en `backend/app/assistant.py`; `backend/README.md` declara que no hay búsqueda clínica ni garantiza precisión de foto. No hay evaluación clínica independiente ni fuentes clínicas integradas. |

## NUT-12 — Peso y ejercicio

| Criterio | Estado y evidencia |
|---|---|
| 12.1 Formularios y chat para peso/actividad | Implementado/test: `TrackingProgressView.swift`, `AssistantObservationReview.swift`, `backend/app/assistant.py`; `NutritionCoreTests.testManualWeightsActivitiesAndChatDraftPersistWithoutHealthOrFoodTotals`, `AssistantObservationReviewTests`; backend prueba propuesta add_weight/add_activity. |
| 12.2 Retener pesajes y regla de duplicados/selección | Implementado/test: `ProgressAnalytics.swift`, `TrackingProgressView.swift`; `ProgressAnalyticsTests.testUnresolvedCrossSourceDuplicateIsExcludedAndVisible`, `testExplicitChoiceKeepsOneHealthOrManualObservation`. Confirmación visual UI pendiente. |
| 12.3 Media móvil 7d con muestras disponibles sin rellenar | Implementado/test: `ProgressAnalytics.swift`; `ProgressAnalyticsTests.testMovingAverageUsesAvailableDaysAndDoesNotFillGaps`. |
| 12.4 Ejercicio separado de calorías de comida | Implementado/test: `ContentView.swift`, `TrackingProgressView.swift`, `HealthKitClient.swift`; `HealthSyncTests.testWorkoutAndActiveEnergyAreSeparateFromDietaryEnergy`, `AssistantObservationReviewTests`. |
| 12.5 Rangos de chart, historial editable y vacío | Implementado: `TrackingProgressView.swift` (Swift Charts, selector de rango, formularios/listas); pruebas visuales de rangos y estados no aparecen en el log UI recibido. |
| 12.6 Procedencia/cobertura/accesibilidad y Salud solo lectura | Implementado/test: `TrackingProgressView.swift`, `HealthViews.swift`, `ProgressAnalyticsTests`, `HealthSyncTests`. Criterios VoiceOver/Dynamic Type/iPad y edición visual final pendientes. |

## NUT-13 — Revisión semanal

| Criterio | Estado y evidencia |
|---|---|
| 13.1 Resumen completo/incompleto de ingesta, proteína, peso y actividad con cobertura | Implementado/test: `ProgressAnalytics.swift`, `TrackingProgressView.swift`, `WeeklyGoalReviewView.swift`; tests de cobertura en `ProgressAnalyticsTests` y `WeeklyGoalReviewTests`. UX final pendiente. |
| 13.2 Umbral de 14 días, ≥10 completos, ≥6 pesajes y ≥3 por semana | Implementado/test/documentado: `ProgressAnalytics.swift`, `backend/app/main.py`, `docs/backend-contract.md`; `ProgressAnalyticsTests.testWeeklyReviewRequiresTenCompleteDaysAndSixWeightsAcrossBothWeeks`, `backend/tests/test_backend.py::test_review_health_aggregate_scope_and_goal_gate`. |
| 13.3 Separar observaciones de explicación, explicar datos/límites | Implementado: `WeeklyGoalReviewView.swift`, response models de `RemoteSession.swift`, `backend/app/assistant.py`; fixtures de coverage y proposal. Revisión de presentación con UI pendiente. |
| 13.4 Cambio solo tras aceptación y versionado | Implementado/test: `WeeklyGoalReviewView.swift`, `WeeklyGoalReviewSupport.swift`, `TrackingSync.swift`, `NutritionStore.swift`; seis `WeeklyGoalReviewTests` pasan, incluidos stale-version, backdate, staging y preservación de versión. No hay aceptación UI remota en el log actual. |
| 13.5 Consentimiento Health mínimo y elección explícita aceptar/rechazar | Implementado/test: `WeeklyGoalReviewSupport.swift`, `WeeklyGoalReviewView.swift`, `backend/app/models.py`; `WeeklyGoalReviewTests.testHealthContextContainsOnlyConsentedDailyAggregatesAndOmitsUnknowns`, backend gate test. UI visual/accesibilidad pendiente. |

## NUT-14 — Ciclo iOS y distribución

| Criterio | Estado y evidencia |
|---|---|
| 14.1 Identidad, firma, icono, HealthKit, privacidad, Release/TestFlight | Parcial: existe archive 1.0 (build 3) firmado con perfil de desarrollo y HealthKit; no es archive de distribución. Upload y TestFlight pendientes. |
| 14.2 Instalación, cámara, picker, safe areas, Dynamic Type, VoiceOver, temas e iPad | Parcial: los cinco UITests chat-first pasaron, incluida navegación en español oscura con Dynamic Type grande y clara estándar. iPad, VoiceOver, cámara/PhotosPicker en iPhone y revisión visual final pendientes. |
| 14.3 Offline, datos locales, Health local y borrador de chat | Implementado/test parcial: `NutritionStore`, `AssistantChatView`, `TrackingSync`; borrador offline pasó y no inventó consumo/respuesta. Transición real de red en dispositivo sigue pendiente. |
| 14.4 Reintento, logout, conflictos y ciclo de proceso | Implementado/test parcial: `TrackingSyncTests`, `RemoteSessionTests`, `NutritionChatIdentityTests`; cubre IDs, owner/cuenta y conflictos. Suspensión/terminación y transición de red en dispositivo pendientes. |
| 14.5 Actualización/migración/recuperación y refresh de Salud | Implementado/test parcial: `NutritionMigrationTests`, `TrackingBackupTests`, `HealthSyncTests`, refresh en foreground. Migración de una instalación previa y recuperación tras una actualización real pendientes. |
| 14.6 Simulator, HealthKit real y distribución | Simulator: 126 XCTest previos y 5 UITests finales sin fallos; backend: 46 pruebas Python. Archive build 3 firmado como desarrollo e instalado en iPhone, pero no pudo lanzarse porque el dispositivo estaba bloqueado. HealthKit real, desbloqueo/launch, revisión visual, archivo de distribución, TestFlight y endpoint HTTPS público siguen pendientes. |

## NUT-15 — Backup, export y validación integral

| Criterio | Estado y evidencia |
|---|---|
| 15.1 Exportar JSON/CSV con campos y procedimiento de backup/restore | Implementado/test: `AppSettingsView.swift`, `TrackingBackup.swift`, `TrackingCSVExport.swift`; `TrackingBackupTests` y `TrackingCSVExportTests`. Share sheet y restore de archivo real pendientes. |
| 15.2 Borrado de cuenta/datos, adjuntos y retención | Implementado/test parcial: `AppSettingsView.swift`, `backend/app/main.py`, `AttachmentFiles`; pruebas de borrado/owner y retención documentada en `backend/README.md`. No hay hosting/backups de producción auditados. |
| 15.3 Flujo completo Health + planilla + comida/foto/chat/progreso | Pendiente como aceptación integral: cinco UITests chat-first pasaron, pero no existe evidencia de extremo a extremo con Health real, archivo importado y foto. El alta de comida se realiza por Chat, sin formulario de macros manual. |
| 15.4 Frases representativas y errores críticos | Implementado/test parcial: fixtures `backend/tests/test_backend.py` para hipotéticos, correcciones, ambigüedad, propiedad e idempotencia; smoke Responses sintético documentado. Uso personal y cobertura lingüística amplia pendientes. |
| 15.5 Costos/latencias de uso personal | Pendiente: backend README registra costos/latencias de smoke, no telemetría de uso personal suficiente para decidir abrir a más personas. |
| 15.6 Share sheet, document picker, Health opt-in y reimportación | Implementado/test parcial: `AppSettingsView.swift`, `TrackingBackup.swift`, `TrackingCSVExport.swift`, `HealthSyncModel.swift`; tests backup/restore/reimport. Validar share sheet, fileImporter, Health real y reinstalación en dispositivo. |

Los estados anteriores solo describen evidencia revisada. No cambiar los checkboxes ni cerrar NUT-01–NUT-15 hasta que se completen los gates reales indicados por `docs/distribution.md`, el backlog y esta matriz.
