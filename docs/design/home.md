# Hoy y Chat — interfaz nativa actual

Actualizado el 9 de octubre de 2026. Las capturas actuales provienen de pruebas de render en español sobre la app SwiftUI; usan un estado vacío sintético y Apple Health está desconectado. No contienen el historial ni valores personales del usuario. Sirven para documentar la UI implementada, no prueban HealthKit real, servicio conectado, accesibilidad completa ni distribución.

## Flujo actual

1. **Hoy** muestra la fecha seleccionada, el estado del día y el resumen nutricional de los datos disponibles. Cuando no hay ingesta registrada, los valores quedan sin dato; la falta de información no se presenta como cero.
2. La acción principal **Registrar comida en el chat** abre Chat. La persona escribe o dicta con el teclado del sistema qué comió. No hay un botón de micrófono propio ni captura de voz personalizada.
3. El asistente propone alimento, cantidad y nutrientes para revisar. La persona puede ajustar la cantidad en la revisión breve o aclarar alimento, preparación y otros detalles por Chat. El registro se guarda con confirmación explícita; las estimaciones no aparecen como hechos antes de la respuesta del servidor. Chat desplaza la conversación a las respuestas nuevas; el botón Done del teclado y Enviar quitan el foco del campo.
4. Las comidas registradas aparecen en Hoy con cantidad, procedencia y nutrientes. **Corregir en el chat** abre Chat con un borrador referido a esa comida; no hay una pantalla de detalle de ejemplo.
5. Salud y planillas se conectan o importan mediante sus flujos separados. Las capturas de esta página muestran Apple Health desconectado y no incluyen sus datos.
6. Hoy permite cerrar y reabrir el día de forma explícita. Chat conserva el borrador sin afirmar que hubo consumo o que se guardó una respuesta cuando no hay conexión.

La navegación nativa ofrece Hoy, Chat y Progreso: inferior en iPhone y superior en iPad; Ajustes está en la barra superior. El catálogo y las recetas guardadas quedan fuera del MVP actual. Los registros manuales de peso y actividad sí están dentro del alcance de Progreso.

## Capturas actuales de prueba en español

Las dos capturas de accesibilidad usan modo oscuro y Dynamic Type máximo. La captura de Hoy muestra el estado sin ingesta; la de Chat muestra el estado de inicio de sesión requerido. La validación automática de render en español pasó, pero estas imágenes por sí solas no acreditan que cada control sea cómodo o que todos los safe areas estén resueltos. En la captura clara de Hoy, la barra inferior se superpone visualmente con parte de la acción primaria en el viewport capturado. Hoy es un `ScrollView` y la acción debería quedar libre al desplazar la pantalla; todavía no hay evidencia de que el control resulte inaccesible. Verificar la interacción y los safe areas antes de aceptar el layout.

| Pantalla | Español estándar | Español con Dynamic Type máximo |
|---|---|---|
| Hoy | [Captura actual clara](home-current-light-es.png) | [Captura actual accesible](home-current-accessibility-es.png) |
| Chat | [Captura actual clara](chat-current-light-es.png) | [Captura actual accesible](chat-current-accessibility-es.png) |

## Maquetas visuales iniciales — referencia histórica

Estas imágenes del 8 de octubre son mockups anteriores a la implementación chat-first. Sus valores, comidas de ejemplo, navegación y conceptos de detalle no representan el estado actual de la app.

- [Mockup inicial de Hoy, modo claro](home-light-es.png).
- [Mockup inicial de Hoy, modo oscuro](home-dark-es.png).
- [Mockup inicial de Hoy, texto accesible grande](home-accessibility-es.png).

## Dirección visual y validación pendiente

La app usa controles SwiftUI, SF Symbols y tipografía del sistema. Los colores acompañan a etiquetas y cantidades, no son su único identificador. La falta de nutrientes permanece como desconocida y la energía activa se muestra separada de la ingesta. Dynamic Type debe poder ampliar contenido mediante desplazamiento; VoiceOver, safe areas, iPad y la revisión visual de todas las pantallas actuales requieren aceptación adicional.

La aceptación de permisos y datos personales de HealthKit en iPhone, el endpoint HTTPS accesible desde iPhone, el archivo firmado para distribución y TestFlight siguen pendientes.

## iPad: navegación y estados vacíos

Dos pruebas de UI pasaron en iPad Pro 13 (M5), con modo claro estándar y oscuro con texto máximo, en vertical y horizontal. Se esperó la geometría de la ventana después de rotar y se capturó la pantalla completa del simulador. Las capturas no contienen Salud ni datos personales.

- [Hoy vertical](ipad-home-portrait-es.png).
- [Chat horizontal](ipad-chat-landscape-es.png).
- [Chat con texto máximo](ipad-chat-accessibility-es.png).
- [Progreso horizontal con texto máximo](ipad-progress-landscape-accessibility-es.png).

Los flujos de archivos, fotos, teclado con datos y VoiceOver siguen pendientes de aceptación adicional.
