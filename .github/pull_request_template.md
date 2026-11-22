## Descripción del Cambio
<!-- Resumen conciso de los cambios introducidos en Zanate -->

## Tipo de Cambio
- [ ] Corrección de bug (`fix`)
- [ ] Nueva funcionalidad (`feat`)
- [ ] Refactorización o mejora técnica (`refactor`)
- [ ] Tarea de CI/CD / Mantenimiento (`chore`)
- [ ] Documentación / ADR (`docs`)

## Checklist de Verificación y Calidad
- [ ] `flutter analyze` ejecutado en `comunidad_universitaria/` sin errores ni advertencias fatales.
- [ ] `flutter test` ejecutado en `comunidad_universitaria/` con todas las pruebas aprobadas.
- [ ] `python3 scripts/ci/check_sql_contracts.py` ejecutado desde la raíz con salida 0 (sin contratos rotos).
- [ ] Pruebas pgTAP (`scripts/db/run_pgtap.sh`) y/o Vitest (`workers/verification`) ejecutadas si los cambios impactan base de datos o Cloudflare Workers.
- [ ] Impacto coordinado con `PEMTREE-admin` evaluado (esquema compartido en proyecto `hfvsstkfqszpjrsrwhql`).
- [ ] Actualización de ADR realizada si se alteró algún contrato de base de datos, RPC o API.
- [ ] Confirmación de directriz Zero-PII: sin almacenamiento local de PII ni regresiones en `local_storage_service.dart`.
