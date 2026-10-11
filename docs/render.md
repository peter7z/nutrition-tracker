# Backend en Render

La configuración reproducible está en `render.yaml`: servicio Python desde
`backend/`, rama `main`, una instancia de 512 MB y disco persistente de 1 GB.
El servicio y el disco requieren un plan pago; consultar el precio vigente
en Render antes de cambiar el tamaño. No se configura OpenAI ni se carga
información real de Salud durante el deploy.

## Estado al 10 de octubre de 2026

La API key local fue validada. El workspace disponible es `My Workspace`.
La creación del servicio fue rechazada porque Render no puede obtener el
repositorio privado `peter7z/nutrition-tracker`. No se creó un servicio ni
se confirmó un endpoint público.

La validación del Blueprint devolvió `need_payment_info` para el servicio:
también falta configurar un medio de pago en ese workspace. La validación
completa y el deploy quedan pendientes de resolver ambos requisitos.

Habilitar el repositorio en la instalación de GitHub de Render:
https://github.com/apps/render/installations/new. Si todavía no está conectado,
agregar GitHub en Account Settings → Git Deployment Credentials de Render.
Luego crear el servicio con esta configuración o sincronizar el Blueprint.

## Operación

- Build: dependencias fijadas mediante `requirements-lock.txt`.
- Arranque: Uvicorn en `$PORT`; TLS termina en el proxy de Render.
- Se confían los encabezados reenviados del proxy en este entorno administrado.
  No reutilizar este comando para un servidor expuesto directamente.
- SQLite y sus archivos auxiliares quedan bajo `/var/data/nutrition/`.
  El disco conserva datos entre deploys; usar una sola instancia.
- Migraciones al arrancar; `/healthz` comprueba conexión y versión del esquema.
- Auto deploy tras pasar los checks de GitHub en `main`.
- La clave `.render` es exclusivamente local y está ignorada por Git.

## Verificación pendiente tras habilitar GitHub

Confirmar deploy `live` y SHA, HTTPS `/healthz`, respuesta 401 de un endpoint
privado sin sesión, autenticación con una cuenta sintética y conservación de
esa cuenta después de un nuevo deploy. Borrar la cuenta de prueba al terminar.
No declarar el servicio listo antes de completar estas comprobaciones.

Esto publica el backend existente. El plugin de ChatGPT, OAuth y el envío
de peso desde Apple Health siguen siendo trabajo pendiente en el backlog.

Referencias: https://render.com/docs/git-provider,
https://render.com/docs/disks, https://render.com/docs/blueprint-spec.
