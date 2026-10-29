# GenVar-PE · MVP web

Aplicación web (Flask + PostgreSQL) del proyecto final de CS2041 Base de Datos I (UTEC):
consultas C1–C8, exploración de tablas, procedimientos y triggers, roles y comparación de índices.

- `web/` aplicación Flask · `exp/consultas.py` consultas del experimento · `sql/` scripts de la base.
- Variables: `DATABASE_URL` (o `GENVAR_DSN`) para la conexión y `GENVAR_SOLO_LECTURA=1` para la versión pública.
- Local: `cd web && pip install -r requirements.txt && python app.py` → http://localhost:5000
