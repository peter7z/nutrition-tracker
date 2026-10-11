# MCP de Nutrition Tracker

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

Antes de escribir, consultar `get_day`. Reintentar con el mismo
`operation_id` y los mismos argumentos devuelve el recibo original sin
duplicar registros. Una revisión desactualizada falla sin guardar cambios.
