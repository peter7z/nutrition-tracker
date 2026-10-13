# Progreso: gráficas de peso

Actualizado el 12 de octubre de 2026.

La tarjeta muestra el último peso del período visible, su fecha y la diferencia entre la primera y la última medición disponible. El selector ofrece Semana (7 días), Mes (30 días, vista inicial), 90 días y Año (365 días). La vista abre en el período que incluye hoy según la zona horaria del perfil.

La gráfica permite desplazamiento horizontal nativo por todo el historial guardado. El selector controla el ancho de la ventana; arrastrar cambia sus fechas, resumen y escala vertical. El desplazamiento se ajusta a días de calendario y se detiene en el inicio del historial y el período más reciente. Cambiar el zoom conserva el extremo final del período explorado cuando el historial lo permite. «Reciente» vuelve a la ventana que termina hoy. Tocar una medición mantiene disponible el detalle, y el desplazamiento vertical de la página sigue funcionando.

El eje vertical se calcula con los pesos diarios y las medias visibles, con un margen del 15 % y una amplitud mínima de 1 kg antes de agregar el margen. Se redondean los límites hacia afuera a décimas. Esto permite ver cambios pequeños sin comenzar siempre en cero ni exagerar una serie constante. No se descartan extremos válidos.

Los puntos grises representan mediciones diarias y la línea verde con relleno suave representa la media de siete días. Los días sin mediciones permanecen ausentes y separan los segmentos. Tocar la gráfica selecciona la medición disponible más cercana y muestra su peso y fecha en la cabecera. Cambiar de período limpia la selección.

Las medias y la conciliación se calculan sobre el historial completo y se conservan mientras no cambian las fuentes. Solo se dibujan los puntos cercanos a la ventana para evitar renderizar años de mediciones en cada movimiento. La media conserva el contexto de los seis días anteriores al inicio visible. El resumen de 14 días mantiene su ventana reciente completa al seleccionar Semana o explorar fechas antiguas. Las mediciones originales del período visible siguen disponibles en un desplegable. Una ventana sin mediciones conserva la gráfica desplazable y muestra el estado sin datos.

Las capturas usan 45 días de datos sintéticos con un intervalo sin mediciones, en español, sobre iPhone 17 Pro con iOS 26.5. No contienen datos personales ni verifican HealthKit real.

- [Vista mensual](progress-weight-month-es.png).
- [Vista semanal](progress-weight-week-es.png).
- [Selección de una medición](progress-weight-selected-es.png).
- [Gráfica oscura con texto de accesibilidad](progress-weight-week-dark-accessibility-es.png).
- [Vista mensual desplazada a fechas anteriores](progress-weight-scrolled-month-es.png).
- [Vista semanal desplazada](progress-weight-scrolled-week-es.png).

La verificación incluye pruebas de escala para fluctuaciones pequeñas, una medición, peso constante, extremos y valores inválidos; límites de desplazamiento, precisión en medianoche y cambios de horario; pruebas existentes de conciliación y medias; y pruebas de interfaz para los cuatro períodos, selección, texto grande, desplazamiento histórico, cambio de zoom conservando fechas, retorno a Reciente, desplazamiento vertical y conservación del resumen de 14 días.

Resultado: compilación aprobada, 18 pruebas unitarias relevantes aprobadas entre `/tmp/NutritionTrackerProgressScrollTests.xcresult` y `/tmp/NutritionTrackerProgressScrollTests2.xcresult`, y tres pruebas de interfaz finales aprobadas en `/tmp/NutritionTrackerProgressScrollFinal.xcresult`. Las capturas corresponden a esta última ejecución.
