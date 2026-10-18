# Medidas corporales

Bocado guarda mediciones fechadas en centímetros en el almacén común del backend.
Cada campo es opcional; un registro necesita al menos una medida:

- `neck_cm`
- `waist_navel_cm`
- `waist_minimum_cm`
- `biceps_cm`
- `thigh_cm`
- `hip_cm`

El MCP expone `record_body_measurements` para escritura y
`get_body_measurements` para lectura por rango inclusivo de fechas. Las escrituras
son registros históricos idempotentes y quedan dentro del mismo aislamiento de
cuenta y revisión que el resto del tracking.

La sincronización con Apple Health es optativa en iOS. HealthKit ofrece un tipo
de cintura, pero no tipos separados para la cintura al ombligo, cintura mínima,
cuello, bíceps, muslo o cadera. Bocado exporta solamente `waist_navel_cm` como
circunferencia de cintura; las demás medidas permanecen en Bocado y se pueden
leer mediante MCP. La app solicita permiso de escritura explícito y solo exporta
cuando la persona activa la sincronización. [Tipo waist circumference de
HealthKit](https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/waistcircumference).
