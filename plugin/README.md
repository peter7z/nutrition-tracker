# Nutrition Tracker — plugin privado 0.1.0

Paquete portable con `plugin.json`, `mcp.json` e instrucciones en
`skills/nutrition-tracking/SKILL.md`. La pieza remota vive en el backend del
monorepo y comparte Postgres, propietarios, validaciones y cálculos con la API.

## Conectar

En ChatGPT Plugins, agregar un MCP propio con:

- URL: `https://nutrition-tracker-api-cljy.onrender.com/mcp`.
- OAuth con registro dinámico (DCR); sin client secret.
- Scopes: `tracking:read tracking:write`.

Completar login o creación de cuenta en Nutrition Tracker y autorizar los
permisos. La contraseña nunca se entrega al chat. Si el host ofrece importar
paquetes locales, importar esta carpeta para incluir también las instrucciones.
Conectar solo la URL valida el MCP, no acredita la instalación del paquete.

El servidor permite el callback estable de ChatGPT y callbacks específicos
`https://chatgpt.com/connector/oauth/<id>`; otros hosts requieren agregar su URL
exacta mediante `OAUTH_REDIRECT_URIS`, separadas por comas. Nunca usar wildcards
para callbacks propios. OAuth publica discovery, PKCE S256, resource, scopes,
access tokens opacos de una hora, refresh rotatorio y revocación persistida.

Herramientas: `get_profile`, `get_day`, `get_progress`, `record_food`,
`update_food`, `delete_food`. ChatGPT estima el snapshot; no hay catálogo ni
inferencia de OpenAI en el servidor. Las mutaciones devuelven recibos y exigen
revisión/versiones. Los widgets se incorporarán mediante Extensions después.

## Verificación y alcance

Pruebas de protocolo real, OAuth, aislamiento de usuarios, permisos,
idempotencia, corrección/borrado y totales contra SQLite/Postgres. Las pruebas
HTTP y del SDK no sustituyen una conversación en ChatGPT. La instalación del
paquete, la conexión con una cuenta real y móvil/voz se deben verificar en el
host antes de declararlos entregados. No hay publicación en catálogo.

Render Free es una etapa de pruebas; Postgres vence el 9 de noviembre de 2026
(22:48 Uruguay). Ver [deploy](../docs/render.md). No conectar información real
de Salud hasta completar su consentimiento y sincronización (NUT-18).

Referencias oficiales: [paquete](https://developers.openai.com/plugins/build/plugins),
[OAuth](https://developers.openai.com/plugins/build/auth),
[conexión en ChatGPT](https://developers.openai.com/plugins/deploy/connect-chatgpt).

La identidad del paquete y el núcleo portable del MCP se validaron contra los schemas de Agent Plugins. El schema portable MCP publicado todavía no reconoce `extensions`; la declaración OAuth de OpenAI se conserva según su documentación y requiere verificación de importación en el host. No se declara una validación completa del paquete instalado.
