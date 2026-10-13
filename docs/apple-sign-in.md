# Sign in with Apple — cuenta compartida

La app muestra una pantalla de inicio de sesión con Apple antes de permitir
el acceso a Hoy, Progreso o Ajustes. Una sesión vigente guardada en Keychain
permite entrar directamente; una sesión vencida o rechazada vuelve al login.
Ajustes → Cuenta de Bocado muestra la cuenta y permite cerrar sesión.
El backend valida el JWT firmado por Apple con sus claves públicas, issuer,
audience, expiración y nonce de un desafío de cinco minutos, consumido una
sola vez. El token de Nutrition Tracker se guarda en Keychain, únicamente
accesible con el dispositivo desbloqueado y sin migración a otros equipos.
Cerrar sesión revoca el token en el servidor antes de eliminarlo del equipo;
sin conexión se mantiene para reintentar. Al cerrar sesión se vuelve al login
sin borrar el historial de la cuenta ni los originales de Apple Health.
Las sesiones vencen a los 30 días.

La identidad estable de Apple se vincula al usuario del backend. Al conectar
por primera vez, **se une automáticamente una cuenta existente con el mismo
email verificado en el token de Apple**, según la decisión del producto.
Nunca se acepta un email enviado por separado desde iOS o un formulario como
prueba de identidad. Las siguientes conexiones usan el subject, incluso si
cambia el correo. Ocultar mi correo puede producir un email relay diferente:
no se une a una cuenta con otro correo. Las cuentas anteriores no verificaban
su email; esta política considera la prueba de Apple autoridad sobre ese
correo. No mezcla ni migra el historial local del teléfono automáticamente.

El plugin ofrece Apple en su consentimiento web cuando la configuración está
completa. Usa el mismo modelo de cuentas y conserva los permisos solicitados
por ChatGPT. El inicio exige CSRF y el retorno exige state ligado al navegador;
el código de Apple se intercambia en el servidor, no se entrega a ChatGPT.
El Services ID debe pertenecer al mismo App ID primario/grupo para conservar
la identidad entre iOS y web.

## Configurar Apple Developer

[Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list):

1. App ID `com.pedrozunino.bocado`, equipo `2KHYMP6SN7`: activar Sign in
   with Apple. El proyecto Xcode ya declara la capability y entitlement.
2. Crear un Services ID, sugerido `com.pedrozunino.bocado.web`, activar
   Sign in with Apple y seleccionar ese App ID primario.
3. Registrar dominio `nutrition-tracker-api-cljy.onrender.com` y return URL
   exacta `https://nutrition-tracker-api-cljy.onrender.com/oauth/apple/callback`.
4. Crear una key Sign in with Apple asociada al App ID y descargar su `.p8`
   una sola vez. Guardar Key ID y Team ID. No versionar ni pegar la clave en chat.

Variables de Render:

- `APPLE_APP_ID=com.pedrozunino.bocado` (default del backend).

  Si el backend desplegado define explícitamente `APPLE_APP_ID`, actualizar ese valor al nuevo Bundle ID y desplegar el cambio antes de probar el login Apple de Bocado. El App ID, el Services ID y su asociación se configuran en Apple Developer; cambiar los defaults del repositorio no modifica esos registros ni las variables del servidor desplegado.
- `APPLE_SERVICE_ID`: Services ID registrado.
- `APPLE_TEAM_ID`: Team ID del equipo propietario.
- `APPLE_KEY_ID`: ID de la key.
- `APPLE_PRIVATE_KEY`: contenido PEM del `.p8`, como secreto. Se admiten saltos
  de línea reales o `\n`. El client secret ES256 se genera con duración de cinco minutos.

Sin esos cuatro valores web, el botón del plugin permanece oculto; iOS puede
verificar identity tokens usando el App ID y claves públicas de Apple. Nunca
se habilita un modo que omita firmas ni se inventan IDs/keys de producción.

## Alcance y aceptación

El login no incorpora aún la consulta/caché de historial remoto en las gráficas
iOS ni el upload de Salud. Esas entregas siguen en NUT-19 y NUT-18.
Las pruebas usan JWT sintéticos firmados con RSA y verifican unión por correo,
subject persistente, permisos de cuenta, replay, firma/issuer/audience/nonce,
expiración, eliminación y acceso web/plugin al mismo usuario, SQLite/Postgres.
Los tests de iOS verifican Keychain mediante un doble, sesión expirada,
identidad devuelta por el servidor, bearer y logout con errores de conexión.

Falta aceptar login Apple real en dispositivo y navegador una vez configurados
App ID, Services ID y key. Esta primera entrega no persiste refresh tokens de
Apple: la revocación directa en Apple, notificaciones server-to-server y la
revocación de la autorización Apple al eliminar la cuenta requieren una fase
adicional antes de distribución pública. La eliminación existente del backend
sí elimina la identidad, las sesiones y los datos de Nutrition Tracker.

[Configuración oficial web](https://developer.apple.com/help/account/capabilities/configure-sign-in-with-apple-for-the-web) ·
[Verificación de identidad](https://developer.apple.com/documentation/signinwithapple/authenticating-users-with-sign-in-with-apple).


## Deploy y verificación — 11 de octubre de 2026

Commit `e8222053d876615792247e6e72ed470122efbec8`, Render
`dep-db5g4lrrjlhs73aonrsg` live, schema 4.
[CI](https://github.com/peter7z/nutrition-tracker/actions/runs/38107531954)
aprobó backend (121 pruebas SQLite/Postgres), iOS (35 unitarias y 4 UI),
Release y privacy manifest. El primer intento tuvo un fallo al abrir Apple
Health en el Simulator de CI; el job repetido pasó sin cambios de código.

La prueba pública verificó desafío Apple, rechazo de token inválido y sesión
ausente, y el flujo OAuth/MCP previo: registro/corrección/borrado, totales,
idempotencia, aislamiento, scopes y renovación/revocación. Se eliminaron las
cuentas sintéticas. La obtención de claves públicas Apple se verificó con
TLS y CA certifi. No se probó un Apple ID real ni se enviaron datos de Salud.
La activación web y aceptación Apple real requieren la configuración anterior.
