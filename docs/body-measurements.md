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
