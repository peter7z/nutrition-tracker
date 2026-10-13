# MCP de Bocado Log

Transporte HTTP: `/mcp`, autenticado por OAuth. Las consultas requieren
`tracking:read`; las escrituras además requieren `tracking:write`.

| Herramienta | Función |
| --- | --- |
| `get_profile` | Cuenta conectada. |
| `get_day` | Comidas, totales y revisión de una fecha. |
| `get_progress` | Totales y pesos para hasta 90 días. |
| `record_food` | Agregar una comida consumida con sus nutrientes por porción. |
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

`record_food` y `update_food` devuelven `day_summary` con los totales y metas
autoritativos del día después de guardar. Esas herramientas enlazan el recurso
MCP Apps `ui://nutrition-tracker/day-summary-v1.html` para mostrar una tarjeta
inline con calorías, progreso del objetivo disponible, proteínas,
carbohidratos, grasas y fibra. Los valores desconocidos siguen apareciendo
como no disponibles; la tarjeta no vuelve a calcular los totales.

Antes de escribir, consultar `get_day`. Reintentar con el mismo
`operation_id` y los mismos argumentos devuelve el recibo original sin
duplicar registros. Una revisión desactualizada falla sin guardar cambios.
