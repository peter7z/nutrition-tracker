# MCP de Bocado Log

Transporte HTTP: `/mcp`, autenticado por OAuth. Las consultas requieren
`tracking:read`; las escrituras además requieren `tracking:write`.

| Herramienta | Función |
| --- | --- |
| `get_profile` | Cuenta conectada. |
| `get_day` | Comidas, totales y revisión de una fecha. |
| `get_progress` | Totales y pesos para hasta 90 días. |
| `record_food` | Agregar una o varias comidas consumidas como entradas separadas, con gramos y nutrientes por alimento. |
| `update_food` | Corregir una comida por ID y versión. |
| `delete_food` | Borrar una comida identificada y confirmada. |
| `record_day_totals` | Guardar totales explícitos de todo el día como fuente histórica completa. |

Los nutrientes de comidas y días son `energy` (kcal), `protein`,
`carbohydrates`, `fat`, `saturatedFat` y `fiber` (gramos). Los valores
no conocidos se mantienen como `null`, no como cero.

`record_day_totals` recibe `operation_id`, `base_revision`, `day`,
`consumption_text` y `nutrients`. Guarda los totales como fuente histórica
completa y los selecciona para esa fecha. Las comidas existentes siguen
registradas, pero no se suman al total suministrado. No sobrescribe resúmenes
históricos existentes. Esto no crea un estado del día ni bloquea correcciones.
Los snapshots se guardan automáticamente al registrar la primera comida del día
siguiente y se versionan si luego cambia el historial.

`record_food` recibe `foods`, una lista de 1 a 20 alimentos. Cada elemento lleva
nombre, comida, fecha/hora, `serving_size_grams`, descripción de la porción,
fuente y nutrientes totales de esa cantidad. Por ejemplo, arándanos de 125 g y
yogur de 100 g son dos elementos y quedan como dos entradas del historial. Las
macros de cada elemento describen su porción consumida, no valores por 100 g;
los nutrientes se calculan y muestran por separado. `get_day`, `day_summary` y
el historial desplegable de `open_tracker` incluyen gramos y totales por
entrada. Los alimentos de un lote
deben pertenecer al mismo día local. El argumento singular `food` se conserva
para clientes anteriores.

El endpoint HTTP `POST /v1/foods` acepta el mismo lote, más `operation_id`,
`base_revision` y `consumption_text`, y lo guarda de forma atómica. Cada entrada
del historial conserva la cantidad en gramos y devuelve `totals` calculados por
el servidor. El endpoint general `POST /v1/sync` sigue aceptando varias
operaciones para sincronización.

`record_food` y `update_food` devuelven `day_summary` con los totales y metas
autoritativos del día después de guardar. Esas herramientas enlazan el recurso
MCP Apps `ui://nutrition-tracker/day-summary-v1.html` para mostrar una tarjeta
inline con calorías, progreso del objetivo disponible, proteínas,
carbohidratos, grasas y fibra. Los valores desconocidos siguen apareciendo
como no disponibles; la tarjeta no vuelve a calcular los totales.

Antes de escribir, consultar `get_day`. Reintentar con el mismo
`operation_id` y los mismos argumentos devuelve el recibo original sin
duplicar registros. Una revisión desactualizada falla sin guardar cambios.

## Identidad del recurso de UI

La conexión existente de ChatGPT usa `ui://nutrition-tracker/day-summary-v1.html`.
Es el único recurso HTML: siempre entrega la interfaz actual de Bocado Log.
El URI es una identidad estable, no la versión del diseño; no crear recursos
v2/v3 ni aliases al actualizar la interfaz. Todas las herramientas con UI
referencian el mismo recurso y permanecen disponibles al modelo y la interfaz.
`open_tracker` además declara el entrypoint global de ChatGPT.

## Panel interactivo (14 de octubre de 2026)

`open_tracker` devuelve el día actual según la zona de la cuenta y los últimos
30 días de progreso. La misma UI conserva la tarjeta inline para respuestas
que no incluyen `dashboard`. El panel permite cambiar de fecha con flechas,
calendario o Hoy, expandir notas de comidas, consultar el peso del día y explorar
la evolución en ventanas de 7, 30 y 90 días. Los puntos del gráfico muestran
mediciones individuales; los días sin peso no se convierten en ceros.
La media de calorías usa únicamente días con un total conocido y conciliado,
y se etiqueta como consumo registrado, no como cobertura completa.

Los controles consultan `get_day` y `get_progress` mediante el puente MCP Apps.
No guardan registros. Un fallo de consulta conserva la última vista y muestra
un mensaje de reintento. El URI del recurso sigue siendo el mismo.

Para regenerar el bundle y ejecutar pruebas de interacción:

```sh
cd backend/ui
npm ci
npm run build
npx playwright install chromium
npm test
```

Las pruebas incluyen navegación, rangos, selección de puntos, texto no confiable,
estados vacío/error, móvil, modo oscuro y un host MCP Apps simulado. La validación
en ese host no acredita por sí sola el comportamiento en ChatGPT.

Validación del 14 de octubre: deploy Render `dep-db7qq6i5b2lc738u281g` live
con `466ac2542d4f6409ad546169982b7c6e71c1b6eb`; healthcheck correcto y
`open_tracker` consultado con la cuenta conectada. En ChatGPT web se verificó
la apertura global, la gráfica y el cambio a siete días mediante tools/call.
Pasaron 18 pruebas de plugin/peso y las pruebas de UI. La suite SQLite completa
terminó con 70 aprobadas y ocho fallos anteriores; la base sin cambios tenía
69 aprobadas y nueve fallos. Se corrigió el reintento de totales que devolvía
un closedAt nuevo en cada respuesta. Los ocho fallos restantes corresponden
a expectativas antiguas de cierre/snapshots y quedan pendientes.
