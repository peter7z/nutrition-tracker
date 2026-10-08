# Nutrition PWA — alcance y backlog v0.1

Fecha: 5 de octubre de 2026. Estado: 15 issues publicados en peter7z/nutrition-tracker; implementación no iniciada. Los identificadores NUT se corresponden con el índice al final de este documento.

## Objetivo

Reemplazar el flujo personal de tracking nutricional por chat y planilla con una PWA de uso diario: registrar comida con texto o fotos, corregir cantidades, consultar qué cenar y visualizar calorías, macros, peso y ejercicio. Primero un usuario; ampliar luego si resulta útil.

## Evidencia y requisitos

Se revisó la planilla actual seguimiento_calorias_peso.xlsx (versión 16) y se recuperaron requisitos de la conversación “Calorie tracking”; no se inspeccionó una transcripción íntegra. La planilla tiene las pestañas Registro diario y Resumen, cinco días con totales y filas futuras vacías. Guarda fecha, peso, promedio de peso, calorías, proteína, actividad, calorías activas, notas y cambio semanal. Carbohidratos, grasas y detalle de alimentos aparecen parcialmente en notas, no en columnas normalizadas. La extracción muestra algunos campos de resumen vacíos: no asumir que son cero ni que se han evaluado sus fórmulas.

Requisitos conservados del flujo:

- Registrar por conversación, con cantidades exactas o aproximadas y correcciones posteriores.
- Mostrar kcal, proteína, carbohidratos y grasas de la comida y acumulado del día en cada respuesta de tracking.
- Distinguir peso crudo/cocido, gramos/mililitros, cantidad consumida y sobrantes.
- Marcar estimaciones y supuestos; preguntar cuando una ambigüedad cambie materialmente el registro.
- Cerrar el día solo mediante una acción explícita. El cierre actual dispara la escritura de la planilla.
- Incluir peso, actividad y tendencias; permitir consultas nutricionales y recomendaciones de comidas.

Propuesta de adaptación: en la PWA, guardar cada entrada como parte del día abierto para no perderla al cerrar el navegador. “Cerrar día” finaliza un resumen; no es el único momento de persistencia. No modificar ni sincronizar automáticamente la planilla original. La base de datos de la app pasa a ser la fuente del tracking nuevo tras la migración elegida por el usuario.

## Alcance y experiencia

**Hoy:** consumido/objetivo de kcal y macros, lista editable de comidas, indicadores de estimación, peso/actividad y acción de cierre. Mostrar cuánto falta o cuánto se excedió sin ocultar el valor.

**Chat:** texto, adjuntar o tomar foto, preguntas y registro. Una sugerencia o una frase futura (“capaz como pollo”) no registra comida consumida. Una orden clara (“anotá…”) sí; las propuestas ambiguas quedan pendientes. Historial recuperable y resumen nutricional obtenido de la base.

**Progreso:** historial diario, medias de ingesta, pesajes y tendencia. Distinguir días abiertos, cerrados, incompletos y sin registro; ausencia de datos nunca equivale a consumo cero.

**Ajustes:** objetivos editables, preferencias alimentarias, zona horaria, exportar/borrar datos. Objetivos iniciales se confirman al configurar, sin convertir recomendaciones históricas en prescripciones vigentes.

### Decisiones técnicas propuestas

- React + TypeScript y backend Node/TypeScript, alineados con la experiencia del usuario. Framework, hosting, base de datos y autenticación se fijan en NUT-01; no se contratan servicios en esta fase.
- Base relacional con registros por usuario, aunque el acceso inicial sea de una sola persona.
- Backend intermediario para OpenAI; ninguna clave secreta en navegador.
- IA para interpretar y sugerir; backend para validar, persistir, sumar y aplicar cambios atómicos. Modelo y API concretos se verifican al implementar, con evaluación de calidad y costo.
- Fuente nutricional conservada por entrada: etiqueta, catálogo o estimación. Guardar una copia de los valores usados para que cambiar un producto no reescriba el pasado.
- API de la app con operaciones acotadas; el asistente no ejecuta SQL libre ni puede acceder a otro usuario.
- Zona horaria de perfil, inicialmente America/Montevideo. Separar instante de registro y fecha del consumo.

Entidades iniciales: User/Profile, GoalVersion, DayLog, Meal, FoodEntry, FoodDefinition, WeightEntry, ActivityEntry, ChatMessage, Attachment, ChangeEvent, ImportBatch. Nutrientes desconocidos son null. DayLog admite resumen histórico importado sin inventar Meal/FoodEntry. Las calorías declaradas por etiqueta se conservan aunque difieran del cálculo aproximado 4/4/9.

### Fuera de la primera versión

App nativa, integración automática con Apple Health, pagos, red social, administración multiusuario, wearables, voz propia, escaneo de códigos de barras, IA offline y sincronización bidireccional con Excel. Las fotos y recomendaciones sí pertenecen a la primera versión completa. Saturadas se admiten desde el modelo; micronutrientes completos quedan para después.

## Organización de trabajo

Destino: repositorio privado peter7z/nutrition-tracker en GitHub, Issues para tareas y Projects opcional para tablero. Estados: Backlog → Ready → In progress → Review → Done. Mantener una tarea en implementación a la vez. Cada PR enlaza su issue y demuestra sus criterios. Prioridad P0: base necesaria; P1: completar la experiencia solicitada; P2: mejora posterior. Tallas S/M/L son relativas, no promesas de tiempo.

Referencia de capacidades GitHub: https://docs.github.com/en/issues/tracking-your-work-with-issues/learning-about-issues/planning-and-tracking-work-for-your-team-or-project

## Orden sugerido

| Hito | Tickets | Resultado |
|---|---|---|
| 0. Definición | 01 | Decisiones y flujo acordados |
| 1. Registro confiable | 02–06 | Login, registro manual, cierre, dashboard e historial importado |
| 2. Conversación | 07–09 | Registro por chat, correcciones y productos frecuentes |
| 3. Experiencia completa | 10–12 | Fotos, sugerencias, peso y ejercicio |
| 4. Uso diario | 13–15 | Revisión de progreso, PWA y exportación/recuperación |

## Tickets listos para GitHub

### NUT-01 — Definir flujo móvil y decisiones de arquitectura

P0 · S · Dependencias: ninguna · Tipo: definición.

Objetivo: cerrar las decisiones que condicionan implementación sin diseñar una plataforma comercial.

Criterios de aceptación:
- Wireframes de Hoy, Chat y Progreso, con ejemplos de añadir, corregir y cerrar un día.
- Registrar elección de framework, hosting, base, autenticación, fuente nutricional inicial y presupuesto mensual de IA.
- Validar persistencia del día abierto, diferencia entre planificar y consumir y objetivos editables.
- Documentar contrato de datos y operaciones del asistente; repositorio destino: `peter7z/nutrition-tracker`.

### NUT-02 — Crear base del proyecto, acceso privado y despliegue de desarrollo

P0 · M · Depende de: 01.

Objetivo: disponer de una app accesible en móvil con identidad y datos privados.

Criterios de aceptación:
- Frontend y backend arrancan con configuración documentada y migraciones reproducibles.
- Login y logout funcionan; todas las rutas de datos exigen usuario autenticado.
- Datos, fotos y consultas se filtran por propietario; una prueba con dos identidades impide acceso cruzado.
- Secretos solo en servidor, entornos separados y despliegue de desarrollo verificable.

### NUT-03 — Registro manual de alimentos y cálculo nutricional

P0 · M · Depende de: 02.

Objetivo: construir la fuente de verdad antes de introducir el chat.

Criterios de aceptación:
- Crear, editar y borrar alimentos de una comida con cantidad, unidad, estado crudo/cocido, fecha, nutrientes y procedencia.
- Soportar valores por 100 g, 100 ml o porción con conversión explícita; no asumir densidad universal.
- Totales por comida y día se calculan en código; nutrientes faltantes se identifican como desconocidos.
- Reintentos no duplican entradas; correcciones tienen versión y pueden deshacerse.
- Casos verificados: porción parcial, cambio de cantidad, saturadas desconocidas y etiqueta que no coincide exactamente con 4/4/9.

### NUT-04 — Día abierto, cierre y correcciones históricas

P0 · S · Depende de: 03.

Criterios de aceptación:
- Las entradas del día abierto sobreviven recargas; cierre solo mediante botón u orden explícita.
- Cerrar guarda un resumen versionado y estado de completitud; repetir cierre no duplica nada.
- Corregir un día cerrado exige reabrirlo explícitamente y conserva historial de cambios.
- “Hoy”, “ayer” y fecha explícita usan la zona horaria del usuario; pasar medianoche no cierra un día automáticamente.

### NUT-05 — Dashboard Hoy con calorías y macros

P0 · M · Depende de: 03, 04.

Criterios de aceptación:
- Mostrar kcal, proteína, carbohidratos y grasas consumidas, objetivos y diferencia; saturadas como dato adicional cuando existan.
- Actualizar al registrar o corregir; mostrar detalle por comida y procedencia de estimaciones.
- Metas editables con fecha de vigencia; cambiar meta no altera registros anteriores.
- Estados vacío, cargando, error y día incompleto; interfaz legible en pantalla de teléfono y con lector de pantalla.

### NUT-06 — Importar historial de la planilla sin inventar desglose

P0 · M · Depende de: 03, 04.

Criterios de aceptación:
- Previsualizar mapeo de Registro diario y Resumen antes de confirmar importación.
- Importar fechas, kcal, proteína, peso, actividad, notas y estado cerrado; filas futuras vacías se omiten.
- Carbohidratos/grasas solo se extraen de totales explícitos en notas, conservando procedencia; conflictos se señalan para revisión.
- Guardar los totales diarios originales como resumen histórico; no fabricar comidas ni volver a sumarlas sobre esos totales.
- Importación idempotente por archivo/lote y fecha; deshacer lote sin borrar datos creados después.
- Comparación por fecha contra fuente, informe de faltantes y registro de divergencias. No escribir en la planilla original.

### NUT-07 — Integrar chat de consultas con contexto persistente

P0 · M · Depende de: 02, 03, 05.

Criterios de aceptación:
- API de OpenAI consumida desde backend, con modelo configurable, límite de gasto, límites por usuario y manejo de timeout.
- Contexto incluye objetivos, preferencias, día seleccionado y totales consultados desde la base; no depende de reenviar todo el historial.
- Mensajes persisten; respuesta no inventa que guardó datos si no hubo operación exitosa.
- Respuestas de tracking terminan con kcal y macros acumulados; consultas funcionan sin modificar ingesta.
- Registrar latencia, tokens/costo estimado y errores sin exponer fotos o contenido sensible en logs.

### NUT-08 — Registrar y corregir comidas conversacionalmente

P0 · L · Depende de: 07, 04.

Criterios de aceptación:
- Operaciones tipadas para añadir, actualizar, eliminar, consultar y cerrar; autorización y validación del lado servidor.
- “Anotá 150 g de banana” crea una entrada; “eran 100 g” actualiza esa entrada sin sumar otra.
- “¿Y si como una banana?” y “¿qué ceno?” no registran consumo.
- Pregunta cuando haya varias entradas candidatas o una unidad materialmente ambigua; permite deshacer una acción.
- Mensaje repetido, reintento de herramienta y desconexión durante respuesta no duplican registros; conflicto entre dos pestañas se detecta.
- El chat y el dashboard muestran los mismos totales luego de cada operación.

### NUT-09 — Guardar productos frecuentes, etiquetas y recetas

P1 · M · Depende de: 03, 08.

Criterios de aceptación:
- Guardar productos con nombre/marca, porción y nutrientes, y seleccionarlos al mencionarlos otra vez.
- Priorizar etiqueta confirmada sobre estimación genérica; si la marca o versión es ambigua, pedir elección.
- Receta con ingredientes, peso total final o porciones y cantidad consumida; sobrantes no se contabilizan como consumidos.
- Editar producto cambia futuras entradas; aplicar a registros existentes requiere acción explícita.

### NUT-10 — Estimar comidas y leer etiquetas desde fotos

P1 · L · Depende de: 07, 08, 09.

Criterios de aceptación:
- Capturar o adjuntar foto en móvil, validar tipo/tamaño y manejar formatos del dispositivo mediante conversión soportada.
- Devolver componentes editables, cantidad estimada, kcal/macros y supuestos; no presentar gramos deducidos visualmente como medición.
- Pedir peso o aclaración cuando sea necesario; estimación visual se confirma antes de registrar.
- Etiqueta: distinguir porción de 100 g/ml, transcribir valores y señalar texto ilegible; usuario confirma antes de guardar producto.
- Adjuntos privados, metadatos de ubicación eliminados y acción de borrar foto; reintentar análisis no duplica comida.

### NUT-11 — Recomendar comidas según el día y responder preguntas

P1 · M · Depende de: 07, 09.

Criterios de aceptación:
- “Tengo pollo y boniato, ¿qué ceno?” produce opciones con cantidades, kcal/macros estimados y total diario proyectado.
- Usar objetivos, preferencias y comida ya registrada; distinguir proyección de acumulado real.
- Registrar solo tras indicar qué se comió; permitir cambios como “usé menos aceite”.
- Explicitar límites de estimaciones y no diagnosticar ni prescribir fármacos; afirmaciones clínicas requieren fuentes verificables o expresar incertidumbre.

### NUT-12 — Registrar peso, ejercicio y mostrar evolución

P1 · M · Depende de: 03, 05, 08.

Criterios de aceptación:
- Peso con fecha/hora y actividad con tipo, duración y calorías activas opcionales, por formulario y chat.
- Múltiples pesajes al día conservados; regla visible para elegir el pesaje diario de la tendencia.
- Media móvil de 7 días calculada sobre observaciones disponibles con número de muestras visible; no rellenar faltantes con cero.
- Ejercicio se muestra separado y no aumenta automáticamente el presupuesto de comida.
- Gráficos con selección de rango, historial editable y estados de datos insuficientes.

### NUT-13 — Revisión semanal y propuestas de ajuste

P1 · M · Depende de: 11, 12, 04.

Criterios de aceptación:
- Resumen de ingesta, registro completo/incompleto, proteína, peso y actividad con cobertura de datos visible.
- Antes de recomendar ajustes, revisar suficiencia de pesajes y días completos durante dos semanas; parámetros se definen y documentan, no se infieren de una fluctuación diaria.
- Diferenciar observaciones calculadas de explicación del asistente; explicar datos usados y limitaciones.
- Objetivos solo cambian tras aceptación; conservar versión previa. Revisión bajo demanda, sin notificaciones programadas en esta entrega.

### NUT-14 — Convertir la app en PWA y verificar uso en iPhone

P1 · M · Depende de: 05, 08, 10, 12.

Criterios de aceptación:
- Manifest, iconos, HTTPS y experiencia standalone verificados en dispositivo objetivo.
- Probar instalación, login persistente, cámara/galería, teclado, áreas seguras y navegación.
- Sin red: indicador explícito, lectura de datos previamente disponibles y borrador local; IA requiere conexión.
- Al recuperar red, reenvío explícito e idempotente de borradores. Logout elimina caché privada.
- Actualizar versión no pierde datos ni conversaciones; indicar diferencias entre navegador y modo instalado.

### NUT-15 — Exportación, recuperación y validación del MVP

P1 · M · Depende de: 06, 08, 10, 11, 12, 13, 14.

Criterios de aceptación:
- Exportar datos estructurados a JSON/CSV con unidades, fechas, fuentes y notas; procedimiento de backup y restauración probado.
- Borrado de cuenta/datos incluye adjuntos y explica retención de backups configurada.
- Verificar flujo completo: importar, añadir comida, corregir, analizar foto, consultar cena, registrar peso/actividad, cerrar día y revisar progreso.
- Evaluación con frases representativas y resultados esperados; errores críticos: duplicar, registrar hipótesis, confundir crudo/cocido, fechar mal o exponer otro usuario.
- Revisar costos y latencias observados en uso personal antes de habilitar más usuarios.

## Mejoras posteriores (P2, todavía sin desarrollar)

Entrada por voz propia; códigos de barras; integraciones de salud/actividad; revisión automática y recordatorios; catálogo nutricional más amplio con micronutrientes; onboarding de más usuarios y controles de cuota. Validar necesidad tras uso real.

## Próximo paso concreto

Comenzar por NUT-01. Esta definición no incluye desarrollo ni despliegue de la aplicación.

## Índice de issues

- [NUT-01 — Definir flujo móvil y decisiones de arquitectura](https://github.com/peter7z/nutrition-tracker/issues/1)
- [NUT-02 — Crear base del proyecto, acceso privado y despliegue de desarrollo](https://github.com/peter7z/nutrition-tracker/issues/2)
- [NUT-03 — Registro manual de alimentos y cálculo nutricional](https://github.com/peter7z/nutrition-tracker/issues/3)
- [NUT-04 — Día abierto, cierre y correcciones históricas](https://github.com/peter7z/nutrition-tracker/issues/4)
- [NUT-05 — Dashboard Hoy con calorías y macros](https://github.com/peter7z/nutrition-tracker/issues/5)
- [NUT-06 — Importar historial de la planilla sin inventar desglose](https://github.com/peter7z/nutrition-tracker/issues/6)
- [NUT-07 — Integrar chat de consultas con contexto persistente](https://github.com/peter7z/nutrition-tracker/issues/7)
- [NUT-08 — Registrar y corregir comidas conversacionalmente](https://github.com/peter7z/nutrition-tracker/issues/8)
- [NUT-09 — Guardar productos frecuentes, etiquetas y recetas](https://github.com/peter7z/nutrition-tracker/issues/9)
- [NUT-10 — Estimar comidas y leer etiquetas desde fotos](https://github.com/peter7z/nutrition-tracker/issues/10)
- [NUT-11 — Recomendar comidas según el día y responder preguntas](https://github.com/peter7z/nutrition-tracker/issues/11)
- [NUT-12 — Registrar peso, ejercicio y mostrar evolución](https://github.com/peter7z/nutrition-tracker/issues/12)
- [NUT-13 — Revisión semanal y propuestas de ajuste](https://github.com/peter7z/nutrition-tracker/issues/13)
- [NUT-14 — Convertir la app en PWA y verificar uso en iPhone](https://github.com/peter7z/nutrition-tracker/issues/14)
- [NUT-15 — Exportación, recuperación y validación del MVP](https://github.com/peter7z/nutrition-tracker/issues/15)
