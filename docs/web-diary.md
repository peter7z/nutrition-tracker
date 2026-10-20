# Consulta web del diario

La interfaz está en `/web` y en `/`, dentro de la misma API de Render.
No necesita un build de iOS ni otro servicio de hosting.

Ingresar con el email y la contraseña de la cuenta conectada a ChatGPT.
Esta primera interfaz utiliza el login por contraseña existente; no incorpora
un nuevo flujo web de Apple. La sesión se mantiene en memoria mientras la
página está abierta, sin guardar tokens en URLs ni en almacenamiento del
navegador. Recargar la página requiere ingresar nuevamente; el botón
Actualizar consulta el servidor sin perder la sesión.

Permite consultar una fecha, navegar al día anterior o siguiente y ver:

- Calorías, proteínas, carbohidratos, grasas, grasa saturada y fibra.
- Comidas, hora, porción y notas.
- Estado abierto/cerrado y fuente de los totales.
- Avisos de fuentes superpuestas y valores desconocidos.

`GET /v1/diary?day=YYYY-MM-DD` requiere la sesión del dueño y utiliza
`context_for`, compartido con MCP. Sin fecha devuelve hoy en la zona horaria
del perfil. Los nutrientes por comida se escalan en el servidor según su
porción. Los cierres históricos sustituyen la fuente de totales sin sumarse
a las comidas. `totals` deja incompletos como desconocidos; `known_totals` suma
lo disponible y se etiqueta como conocido cuando faltan datos de otras comidas.

La interfaz muestra las últimas 50 entradas del día, mientras los totales
consideran todas. No modifica datos nutricionales. Cerrar sesión revoca la
sesión del navegador y limpia los datos visibles.

Validación: pruebas SQLite/PostgreSQL de autenticación, aislamiento, porciones,
fibra y cierres; smoke test real en Chromium de escritorio y móvil, login,
navegación de fechas, refresco, texto no interpretado como HTML y cambio de cuenta.
