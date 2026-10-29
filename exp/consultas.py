"""Las 5 consultas del experimento (Sección 5.1) y sus planes de índices (5.3).
Este archivo es la única fuente: genera también sql/07_consultas.sql y
sql/08_indices.sql para que el informe y el experimento usen el mismo SQL."""

PATOG = "('PATOGENICA','PROBABLEMENTE_PATOGENICA')"

CONSULTAS = {
"C1": dict(
titulo="Reporte clínico de un donante",
descripcion=("Variantes con filtro PASS y profundidad >= 20 detectadas en cualquier muestra "
             "del donante, con anotación patogénica o probablemente patogénica, junto con el gen, "
             "la consecuencia y la condición. Une 7 tablas y filtra por un donante."),
sql=f"""SELECT DISTINCT v.id_variante, v.rsid, v.id_cromosoma, v.posicion, g.genotipo,
       ge.simbolo AS gen, vg.consecuencia, c.nombre AS condicion, a.significancia
FROM muestra m
JOIN genotipo g           ON g.id_muestra   = m.id_muestra
JOIN variante v           ON v.id_variante  = g.id_variante
JOIN anotacion_clinica a  ON a.id_variante  = g.id_variante
JOIN condicion c          ON c.id_condicion = a.id_condicion
LEFT JOIN variante_gen vg ON vg.id_variante = v.id_variante
LEFT JOIN gen ge          ON ge.id_gen      = vg.id_gen
WHERE m.id_donante = %(donante)s
  AND g.filtro = 'PASS' AND g.profundidad >= 20
  AND a.significancia IN {PATOG}
ORDER BY v.id_cromosoma, v.posicion"""),

"C2": dict(
titulo="Portadores por gen",
descripcion=("Para cada gen, número de donantes distintos que portan al menos una variante "
             "patogénica y su porcentaje sobre el total de donantes secuenciados. "
             "Agregación con COUNT DISTINCT, subconsulta EXISTS y CTE."),
sql=f"""WITH total AS (
    SELECT count(DISTINCT m.id_donante) AS n
    FROM muestra m JOIN muestra_corrida mc ON mc.id_muestra = m.id_muestra
), portadores AS (
    SELECT vg.id_gen, count(DISTINCT m.id_donante) AS n_portadores
    FROM genotipo g
    JOIN muestra m       ON m.id_muestra   = g.id_muestra
    JOIN variante_gen vg ON vg.id_variante = g.id_variante
    WHERE EXISTS (SELECT 1 FROM anotacion_clinica a
                  WHERE a.id_variante = g.id_variante AND a.significancia IN {PATOG})
    GROUP BY vg.id_gen
)
SELECT ge.simbolo, p.n_portadores,
       round(100.0 * p.n_portadores / t.n, 2) AS pct_donantes
FROM portadores p JOIN gen ge ON ge.id_gen = p.id_gen CROSS JOIN total t
ORDER BY p.n_portadores DESC, ge.simbolo"""),

"C3": dict(
titulo="Variantes enriquecidas en la cohorte",
descripcion=("Variantes observadas en al menos 10 donantes cuya frecuencia alélica en la "
             "cohorte supera 5 veces la frecuencia poblacional global (gnomAD). Cuenta los "
             "alelos por donante (1/1 aporta 2) para no contar dos veces las re-secuenciaciones."),
sql="""WITH n AS (
    SELECT count(DISTINCT m.id_donante) AS n
    FROM muestra m JOIN muestra_corrida mc ON mc.id_muestra = m.id_muestra
), por_donante AS (
    SELECT g.id_variante, m.id_donante,
           max(CASE g.genotipo WHEN '1/1' THEN 2 ELSE 1 END) AS alelos
    FROM genotipo g JOIN muestra m ON m.id_muestra = g.id_muestra
    GROUP BY g.id_variante, m.id_donante
), f AS (
    SELECT id_variante, count(*) AS n_donantes, sum(alelos) AS alelos
    FROM por_donante GROUP BY id_variante HAVING count(*) >= 10
)
SELECT v.id_variante, v.rsid, v.id_cromosoma, v.posicion, f.n_donantes,
       round(f.alelos::numeric / (2 * n.n), 5)                       AS frec_cohorte,
       v.frec_poblacional,
       round(f.alelos::numeric / (2 * n.n) / v.frec_poblacional, 1)  AS veces
FROM f JOIN variante v ON v.id_variante = f.id_variante CROSS JOIN n
WHERE v.frec_poblacional > 0
  AND f.alelos::numeric / (2 * n.n) >= 5 * v.frec_poblacional
ORDER BY veces DESC"""),

"C5": dict(
titulo="Consulta por región genómica",
descripcion=("Variantes missense o de impacto ALTO en un rango de posiciones de un cromosoma, "
             "con el número de muestras germinales y tumorales en que aparecen. "
             "Filtro por rango, LEFT JOIN a las dos subclases y COUNT ... FILTER."),
sql=f"""SELECT v.id_variante, v.rsid, v.posicion, v.alelo_ref, v.alelo_alt,
       ge.simbolo AS gen, vg.consecuencia, vg.impacto,
       count(DISTINCT g.id_muestra) FILTER (WHERE mg.id_muestra IS NOT NULL) AS germinales,
       count(DISTINCT g.id_muestra) FILTER (WHERE mt.id_muestra IS NOT NULL) AS tumorales
FROM variante v
JOIN variante_gen vg          ON vg.id_variante = v.id_variante
JOIN gen ge                   ON ge.id_gen      = vg.id_gen
JOIN genotipo g               ON g.id_variante  = v.id_variante
LEFT JOIN muestra_germinal mg ON mg.id_muestra  = g.id_muestra
LEFT JOIN muestra_tumoral  mt ON mt.id_muestra  = g.id_muestra
WHERE v.id_cromosoma = %(crom)s AND v.posicion BETWEEN %(ini)s AND %(fin)s
  AND (vg.consecuencia = 'missense_variant' OR vg.impacto = 'ALTO')
GROUP BY v.id_variante, ge.simbolo, vg.consecuencia, vg.impacto
ORDER BY v.posicion"""),

"C6": dict(
titulo="Concordancia técnica entre corridas",
descripcion=("Muestras secuenciadas en más de una corrida: para cada par de corridas, "
             "variantes en común, cuántas tienen genotipo distinto y el porcentaje de "
             "discordancia. Self-join de la tabla más grande."),
sql="""WITH reseq AS (
    SELECT id_muestra FROM muestra_corrida
    GROUP BY id_muestra HAVING count(*) > 1
)
SELECT g1.id_muestra, g1.id_corrida AS corrida_1, g2.id_corrida AS corrida_2,
       count(*)                                          AS variantes_comunes,
       count(*) FILTER (WHERE g1.genotipo <> g2.genotipo) AS discordantes,
       round(100.0 * count(*) FILTER (WHERE g1.genotipo <> g2.genotipo) / count(*), 2)
                                                         AS pct_discordancia
FROM reseq r
JOIN genotipo g1 ON g1.id_muestra = r.id_muestra
JOIN genotipo g2 ON g2.id_muestra = g1.id_muestra
                AND g2.id_variante = g1.id_variante
                AND g2.id_corrida  > g1.id_corrida
GROUP BY g1.id_muestra, g1.id_corrida, g2.id_corrida
ORDER BY pct_discordancia DESC, g1.id_muestra"""),
}

# Dos planes de índices por consulta. "Sin índices" = solo los índices que
# PostgreSQL crea por las PRIMARY KEY y UNIQUE (no se pueden quitar sin
# romper la integridad).
PLANES = {
"C1": {
  "A": ("B-tree simples en las llaves foráneas usadas por los joins",
        ["CREATE INDEX ix_muestra_donante ON muestra(id_donante)",
         "CREATE INDEX ix_anot_variante ON anotacion_clinica(id_variante)"]),
  "B": ("B-tree en muestra + índice PARCIAL solo con anotaciones patogénicas",
        ["CREATE INDEX ix_muestra_donante ON muestra(id_donante)",
         f"CREATE INDEX ix_anot_patog ON anotacion_clinica(id_variante) WHERE significancia IN {PATOG}"]),
},
"C2": {
  "A": ("B-tree en genotipo(id_variante)",
        ["CREATE INDEX ix_gen_variante ON genotipo(id_variante)"]),
  "B": ("Índice parcial de anotaciones + índice cubriente genotipo(id_variante) INCLUDE (id_muestra)",
        [f"CREATE INDEX ix_anot_patog ON anotacion_clinica(id_variante) WHERE significancia IN {PATOG}",
         "CREATE INDEX ix_gen_var_cub ON genotipo(id_variante) INCLUDE (id_muestra)"]),
},
"C3": {
  "A": ("B-tree en genotipo(id_variante)",
        ["CREATE INDEX ix_gen_variante ON genotipo(id_variante)"]),
  "B": ("Índice cubriente genotipo(id_variante, id_muestra) INCLUDE (genotipo) para Index Only Scan",
        ["CREATE INDEX ix_gen_var_mue ON genotipo(id_variante, id_muestra) INCLUDE (genotipo)"]),
},
"C5": {
  "A": ("B-tree compuesto variante(id_cromosoma, posicion) + B-tree genotipo(id_variante)",
        ["CREATE INDEX ix_var_region ON variante(id_cromosoma, posicion)",
         "CREATE INDEX ix_gen_variante ON genotipo(id_variante)"]),
  "B": ("B-tree compuesto variante(id_cromosoma, posicion) + índice HASH genotipo(id_variante)",
        ["CREATE INDEX ix_var_region ON variante(id_cromosoma, posicion)",
         "CREATE INDEX ix_gen_var_hash ON genotipo USING hash (id_variante)"]),
},
"C6": {
  "A": ("B-tree compuesto genotipo(id_muestra, id_variante) INCLUDE (genotipo)",
        ["CREATE INDEX ix_gen_mue_var ON genotipo(id_muestra, id_variante) INCLUDE (genotipo)"]),
  "B": ("Mismo índice con el orden de columnas invertido: genotipo(id_variante, id_muestra)",
        ["CREATE INDEX ix_gen_var_mue2 ON genotipo(id_variante, id_muestra) INCLUDE (genotipo)"]),
},
}

# Índices finales recomendados (los que quedan en la base de datos).
# ix_var_region NO queda: el experimento mostró que el UNIQUE de la llave natural
# (id_cromosoma, posicion, alelo_ref, alelo_alt) ya sirve para el filtro por región.
INDICES_FINALES = [
    "CREATE INDEX IF NOT EXISTS ix_muestra_donante ON muestra(id_donante)",
    f"CREATE INDEX IF NOT EXISTS ix_anot_patog ON anotacion_clinica(id_variante) WHERE significancia IN {PATOG}",
    "CREATE INDEX IF NOT EXISTS ix_anot_variante ON anotacion_clinica(id_variante)",
    "CREATE INDEX IF NOT EXISTS ix_gen_var_mue ON genotipo(id_variante, id_muestra) INCLUDE (genotipo)",
    "CREATE INDEX IF NOT EXISTS ix_gen_mue_var ON genotipo(id_muestra, id_variante) INCLUDE (genotipo)",
]

REGION = dict(crom="1", ini=1, fin=50_000_000)

# Alternativa a índices para C3: precalcular la agregación por variante.
MV_C3 = """CREATE MATERIALIZED VIEW mv_frec_variante AS
SELECT id_variante, count(*) AS n_donantes, sum(alelos) AS alelos
FROM (SELECT g.id_variante, m.id_donante,
             max(CASE g.genotipo WHEN '1/1' THEN 2 ELSE 1 END) AS alelos
      FROM genotipo g JOIN muestra m ON m.id_muestra = g.id_muestra
      GROUP BY g.id_variante, m.id_donante) d
GROUP BY id_variante"""

C3_SOBRE_MV = """WITH n AS (
    SELECT count(DISTINCT m.id_donante) AS n
    FROM muestra m JOIN muestra_corrida mc ON mc.id_muestra = m.id_muestra
)
SELECT v.id_variante, v.rsid, v.id_cromosoma, v.posicion, f.n_donantes,
       round(f.alelos::numeric / (2 * n.n), 5)                       AS frec_cohorte,
       v.frec_poblacional,
       round(f.alelos::numeric / (2 * n.n) / v.frec_poblacional, 1)  AS veces
FROM mv_frec_variante f JOIN variante v ON v.id_variante = f.id_variante CROSS JOIN n
WHERE f.n_donantes >= 10 AND v.frec_poblacional > 0
  AND f.alelos::numeric / (2 * n.n) >= 5 * v.frec_poblacional
ORDER BY veces DESC"""
