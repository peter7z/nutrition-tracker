# Medidas corporales

Bocado guarda mediciones fechadas en centímetros en el almacén común del backend.
Cada campo es opcional; un registro necesita al menos una medida:

- `neck_cm`
- `waist_navel_cm`
- `waist_minimum_cm`
- `biceps_cm`
- `thigh_cm`
- `hip_cm`
- `chest_cm`

El MCP expone `record_body_measurements` para escritura y
`get_body_measurements` para lectura por rango inclusivo de fechas. Las escrituras
son registros históricos idempotentes y quedan dentro del mismo aislamiento de
cuenta y revisión que el resto del tracking.

Para corregir una medición existente se usa `update_body_measurements`, sin
crear otro registro. Primero se consulta `get_body_measurements` para obtener
`record_id` (el `id` del registro), `expected_version` y `base_revision`. Se envía
un `operation_id` nuevo y un objeto `changes` con solo los campos a corregir,
por ejemplo `{"waist_navel_cm": 86.5}`. Los campos omitidos conservan su valor,
incluidas la fecha y las notas. Un valor `null` elimina una medida opcional,
pero siempre debe quedar al menos una. La fecha no admite `null`.

La corrección conserva el ID e incrementa la versión y la revisión. Repetir la
misma petición devuelve el mismo recibo sin aplicar otra modificación; reutilizar
el identificador con otros argumentos o escribir sobre una versión antigua
produce un conflicto. Si hay varias mediciones posibles o no está claro el sitio
medido, el asistente debe aclararlo antes de guardar.

La sincronización con Apple Health es optativa en iOS. HealthKit ofrece un tipo
de cintura, pero no tipos separados para la cintura al ombligo, cintura mínima,
cuello, bíceps, muslo, cadera o pecho. Bocado exporta solamente `waist_navel_cm` como
circunferencia de cintura; las demás medidas permanecen en Bocado y se pueden
leer mediante MCP. La app solicita permiso de escritura explícito y solo exporta
cuando la persona activa la sincronización. [Tipo waist circumference de
HealthKit](https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/waistcircumference).


Con la exportación de cintura activada, `BGAppRefreshTask` consulta el diario y
exporta los registros nuevos o con una versión superior. La petición usa una
fecha mínima de 15 minutos; iOS decide cuándo ejecutarla y no garantiza esa
frecuencia. También se aprovechan los avisos de cambios de peso y el desbloqueo
del teléfono. Los identificadores y versiones de HealthKit evitan repetir las
mediciones ya exportadas. Detener la sincronización o cerrar sesión cancela la
petición periódica. No se observa la cintura de Salud: la dirección sigue siendo
Bocado → Apple Health y no se importa ninguna medida desde Salud.

El target declara `fetch`, el identificador permitido de BGTaskScheduler y el
entitlement `com.apple.developer.healthkit.background-delivery`. La distribución
debe usar un perfil de firma compatible con ese entitlement. Simulator permite
validar el coordinador y la compilación, pero la entrega real de HealthKit en
segundo plano requiere validación en un iPhone con permisos concedidos.
