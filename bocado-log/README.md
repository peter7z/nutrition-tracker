# Bocado Log — plugin privado 0.2.1

Paquete portable con `plugin.json`, `mcp.json` e instrucciones en
`skills/bocado-log/SKILL.md`. La pieza remota vive en el backend del
monorepo y comparte Postgres, propietarios, validaciones y cálculos con la API.

## Conectar

En ChatGPT Plugins, agregar un MCP propio con:

- URL: `https://bocado-api-929368612596.us-east1.run.app/mcp`.
- OAuth con registro dinámico (DCR); sin client secret.
- Scopes: `tracking:read tracking:write`.

Completar login o creación de cuenta en Bocado Log y autorizar los
permisos. La contraseña nunca se entrega al chat. Si el host ofrece importar
paquetes locales, importar esta carpeta para incluir también las instrucciones.
Conectar solo la URL valida el MCP, no acredita la instalación del paquete.

El servidor permite el callback estable de ChatGPT y callbacks específicos
`https://chatgpt.com/connector/oauth/<id>`; otros hosts requieren agregar su URL
exacta mediante `OAUTH_REDIRECT_URIS`, separadas por comas. Nunca usar wildcards
para callbacks propios. OAuth publica discovery, PKCE S256, resource, scopes,
access tokens opacos de una hora, refresh rotatorio y revocación persistida.

Herramientas: `get_profile`, `get_day`, `show_day_summary`, `get_progress`, `open_tracker`, `record_food`,
`update_food`, `delete_food`, `record_day_totals`. ChatGPT estima el snapshot;
no hay catálogo ni inferencia de OpenAI en el servidor. Las mutaciones devuelven
recibos y exigen revisión/versiones. Al registrar o corregir una comida, el MCP
entrega los totales autoritativos del día y vincula una tarjeta MCP Apps inline
con calorías, progreso del objetivo disponible, macros y fibra. La entrada
global `open_tracker` abre el resumen diario de solo lectura desde el sidebar.
`record_food` acepta una lista `foods`: cada alimento guarda sus gramos y
nutrientes como entrada independiente; el historial desplegable muestra kcal y
macros por alimento. La API HTTP ofrece el mismo registro atómico en
`POST /v1/foods`.
Este cambio debe desplegarse y reconectarse en ChatGPT para que aparezca.

## Verificación y alcance

Pruebas de protocolo real, OAuth, aislamiento de usuarios, permisos,
idempotencia, corrección/borrado y totales contra SQLite/Postgres. Las pruebas
HTTP y del SDK no sustituyen una conversación en ChatGPT. La tarjeta MCP Apps
está implementada en el servidor; su renderizado real, la instalación del
paquete, la conexión con una cuenta real y móvil/voz se deben verificar en el
host antes de declararlos entregados. No hay publicación en catálogo.

Render Free es una etapa de pruebas; Postgres vence el 9 de noviembre de 2026
(22:48 Uruguay). Ver [deploy](../docs/render.md). No conectar información real
de Salud hasta completar su consentimiento y sincronización (NUT-18).

Referencias oficiales: [paquete](https://developers.openai.com/plugins/build/plugins),
[OAuth](https://developers.openai.com/plugins/build/auth),
[conexión en ChatGPT](https://developers.openai.com/plugins/deploy/connect-chatgpt).

La identidad del paquete y el núcleo portable del MCP se validaron contra los schemas de Agent Plugins. El schema portable MCP publicado todavía no reconoce `extensions`; la declaración OAuth de OpenAI se conserva según su documentación y requiere verificación de importación en el host. No se declara una validación completa del paquete instalado.


### Verificación pública — 10 de octubre de 2026

Render desplegó `a06d63fe9a9580392c8103f77020396b653cc9fc` mediante
`dep-db5f9kjbc2fs738ndggg`. [CI](https://github.com/peter7z/nutrition-tracker/actions/runs/38105072707)
aprobó backend (99 pruebas, SQLite/Postgres) e iOS. La prueba HTTP pública
verificó discovery, OAuth/PKCE, registro/corrección/borrado, totales, reintentos
idempotentes, aislamiento de cuentas/scopes y renovación/revocación. Las dos
cuentas sintéticas se eliminaron al terminar. Instalación y conversación real
en ChatGPT siguen pendientes; no se usaron datos reales de Salud.


### Cuenta con Apple

iOS incorpora Sign in with Apple. La primera conexión une automáticamente
una cuenta existente con el mismo email verificado de Apple; con Ocultar mi
correo, una dirección relay diferente puede crear otra cuenta. Para entrar
con Apple desde el consentimiento del plugin, primero configurar Services ID
y key del mismo App ID primario en Apple Developer/Render. Sin esa configuración
el botón Apple web permanece oculto.
[Configuración y aceptación pendiente](https://github.com/peter7z/nutrition-tracker/blob/main/docs/apple-sign-in.md).
