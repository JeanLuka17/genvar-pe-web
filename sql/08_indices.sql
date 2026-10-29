-- =====================================================================
-- GenVar-PE · Hito 2 · 5.3 Planes de índices evaluados y los índices finales
-- =====================================================================
SET search_path TO genvar;

-- Planes evaluados en el experimento (se crean y se borran uno a la vez):
--   C1 plan A: B-tree simples en las llaves foráneas usadas por los joins
--     CREATE INDEX ix_muestra_donante ON muestra(id_donante);
--     CREATE INDEX ix_anot_variante ON anotacion_clinica(id_variante);
--   C1 plan B: B-tree en muestra + índice PARCIAL solo con anotaciones patogénicas
--     CREATE INDEX ix_muestra_donante ON muestra(id_donante);
--     CREATE INDEX ix_anot_patog ON anotacion_clinica(id_variante) WHERE significancia IN ('PATOGENICA','PROBABLEMENTE_PATOGENICA');
--   C2 plan A: B-tree en genotipo(id_variante)
--     CREATE INDEX ix_gen_variante ON genotipo(id_variante);
--   C2 plan B: Índice parcial de anotaciones + índice cubriente genotipo(id_variante) INCLUDE (id_muestra)
--     CREATE INDEX ix_anot_patog ON anotacion_clinica(id_variante) WHERE significancia IN ('PATOGENICA','PROBABLEMENTE_PATOGENICA');
--     CREATE INDEX ix_gen_var_cub ON genotipo(id_variante) INCLUDE (id_muestra);
--   C3 plan A: B-tree en genotipo(id_variante)
--     CREATE INDEX ix_gen_variante ON genotipo(id_variante);
--   C3 plan B: Índice cubriente genotipo(id_variante, id_muestra) INCLUDE (genotipo) para Index Only Scan
--     CREATE INDEX ix_gen_var_mue ON genotipo(id_variante, id_muestra) INCLUDE (genotipo);
--   C5 plan A: B-tree compuesto variante(id_cromosoma, posicion) + B-tree genotipo(id_variante)
--     CREATE INDEX ix_var_region ON variante(id_cromosoma, posicion);
--     CREATE INDEX ix_gen_variante ON genotipo(id_variante);
--   C5 plan B: B-tree compuesto variante(id_cromosoma, posicion) + índice HASH genotipo(id_variante)
--     CREATE INDEX ix_var_region ON variante(id_cromosoma, posicion);
--     CREATE INDEX ix_gen_var_hash ON genotipo USING hash (id_variante);
--   C6 plan A: B-tree compuesto genotipo(id_muestra, id_variante) INCLUDE (genotipo)
--     CREATE INDEX ix_gen_mue_var ON genotipo(id_muestra, id_variante) INCLUDE (genotipo);
--   C6 plan B: Mismo índice con el orden de columnas invertido: genotipo(id_variante, id_muestra)
--     CREATE INDEX ix_gen_var_mue2 ON genotipo(id_variante, id_muestra) INCLUDE (genotipo);

-- Índices finales que quedan en la base de datos:
CREATE INDEX IF NOT EXISTS ix_muestra_donante ON muestra(id_donante);
CREATE INDEX IF NOT EXISTS ix_anot_patog ON anotacion_clinica(id_variante) WHERE significancia IN ('PATOGENICA','PROBABLEMENTE_PATOGENICA');
CREATE INDEX IF NOT EXISTS ix_anot_variante ON anotacion_clinica(id_variante);
CREATE INDEX IF NOT EXISTS ix_gen_var_mue ON genotipo(id_variante, id_muestra) INCLUDE (genotipo);
CREATE INDEX IF NOT EXISTS ix_gen_mue_var ON genotipo(id_muestra, id_variante) INCLUDE (genotipo);
ANALYZE;
