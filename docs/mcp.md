# MCP de Bocado Log

Transporte HTTP: `/mcp`, autenticado por OAuth. Las consultas requieren
`tracking:read`; las escrituras además requieren `tracking:write`.

| Herramienta | Función |
| --- | --- |
| `get_profile` | Cuenta conectada. |
| `get_day` | Comidas, totales, cierre y revisión de una fecha. |
| `get_progress` | Totales y pesos para hasta 90 días. |
| `record_food` | Agregar una comida consumida con sus nutrientes por porción. |
| `update_food` | Corregir una comida por ID y versión. |
| `delete_food` | Borrar una comida identificada y confirmada. |
| `record_closed_day` | Guardar los totales consumidos de una fecha y cerrar el día. |

Los nutrientes de comidas y días son `energy` (kcal), `protein`,
`carbohydrates`, `fat`, `saturatedFat` y `fiber` (gramos). Los valores
no conocidos se mantienen como `null`, no como cero.

`record_closed_day` recibe `operation_id`, `base_revision`, `day`,
`consumption_text` y `nutrients`. Guarda el resumen y el cierre en una sola
transacción, seleccionando el total histórico como fuente. Las comidas
existentes siguen registradas, pero no se suman al total suministrado.
No sobrescribe cierres ni resúmenes históricos existentes. Un cierre impide
agregar, corregir o borrar comidas de ese día hasta que se reabra.

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
referencian el mismo recurso. Solo `open_tracker` es exclusivo de la interfaz;
las herramientas de resumen y registro permanecen disponibles al modelo.
