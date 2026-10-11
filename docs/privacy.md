# Privacidad del companion iOS

Estado de la limpieza — 10 de octubre de 2026.

La app actual lee Apple Health y consulta el historial guardado. No tiene chat, cámara, registro de comidas/peso/actividad, edición de metas, importación/restauración ni cliente de envío de tracking. No contiene una clave de IA ni inicia solicitudes de red. Su manifiesto declara ausencia de tracking y de recolección fuera del dispositivo en esta versión.

La copia local de Salud conserva tipos/rango elegidos, muestras, procedencia y cursores. Desconectar detiene consultas. Borrar la copia local requiere una acción explícita y no elimina Apple Health ni el historial de tracking. Salud solicita únicamente lectura; no se declaran permisos de cámara ni excepción HTTP para el antiguo servidor local.

La limpieza no borra ni reescribe archivos de tracking, adjuntos o pendientes del enfoque anterior. Los esquemas de compatibilidad siguen leyendo esos campos, pero no reproducen mensajes ni operaciones. Un lector de identidad consulta únicamente el propietario de la sesión anterior en Keychain para seleccionar su archivo local; no utiliza el token ni autentica, cambia o elimina credenciales. La consulta del historial de cada propietario sigue aislada. Si Keychain está inaccesible, la app usa el archivo local; los archivos de cuenta permanecen intactos.

El producto objetivo **sí enviará peso y otros datos seleccionados de Apple Health al servidor**. NUT-18 implementa el consentimiento remoto separado, payload limitado, identidad, revocación, borrado de copia remota y acceso desde el plugin. Antes de habilitar ese transporte deben actualizarse el manifiesto, los textos de consentimiento y las declaraciones de distribución. No se presenta la lectura local como autorización de envío ni se simula una sincronización remota existente.

La política anterior se conserva en [archivo histórico](archive/privacy-ios-chat-2026-10-10.md). El alcance completo está en [producto](product.md).
