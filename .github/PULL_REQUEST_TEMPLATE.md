## Resumen / Summary

<!-- Una o dos frases en español sobre qué cambia y por qué. -->

> English summary: <!-- brief English gloss for the maintainer; optional -->

## Tipo de cambio / Change type

<!-- Marca el tipo. Una sola opción. -->

- [ ] `feat` — Nueva funcionalidad
- [ ] `fix` — Bug fix
- [ ] `refactor` — Cambio interno sin cambio de comportamiento
- [ ] `docs` — Documentación solamente
- [ ] `chore` — Mantenimiento (deps, CI, housekeeping)
- [ ] `test` — Solo tests
- [ ] `perf` — Mejora de performance

## Perfil / Profile impactado

<!-- ¿El cambio afecta a algún deploy profile? Marca todos los que apliquen. -->

- [ ] `lan`
- [ ] `https-public`
- [ ] `https-behind-external-proxy`
- [ ] `frontend-only`
- [ ] Ninguno — el cambio es interno / de tooling

## Cómo probar / How to test

<!-- Pasos concretos para que el maintainer (asotonet) valide el cambio en un VPS limpio.
     Si requiere variables nuevas en .env o un override compose, mencinalas. -->

1.
2.
3.

## Checklist del contributor

- [ ] `git pull --ff-only origin main` aplicado en una copia local
- [ ] `./smartolt.sh install --yes` en un VPS limpio termina con containers healthy
- [ ] `./smartolt.sh status` muestra 3 o 4 containers según el profile
- [ ] Si tocás `smartolt.sh`, corriste `bash -n smartolt.sh` (sin errores de sintaxis)
- [ ] Si tocás `docker-compose.yml`, corriste `docker compose config --quiet` (sin errores)
- [ ] Si agregás una nueva variable al wizard, actualizaste `.env.example` y el README (ES + EN)
- [ ] El commit usa Conventional Commits (`feat:`, `fix:`, etc.)

