# Backend

Carpeta reservada para el backend del monorepo Nutrition Tracker. No contiene todavía un servidor ni define proveedor, framework o base de datos.

NUT-02 define autenticación, persistencia remota, contrato HTTP, migraciones y entornos. NUT-07 agrega el intermediario de IA con claves solo en servidor. La integración HealthKit de NUT-01 funciona en iOS y persiste localmente sin depender del backend.

La app iOS vive en `../ios/`; el backlog está en `../docs/backlog.md`. Documentar aquí comandos de desarrollo, configuración mediante `.env.example` sin secretos, migraciones y validaciones cuando se implemente el servicio. Datos de Apple Health no se envían al servidor sin consentimiento explícito.
