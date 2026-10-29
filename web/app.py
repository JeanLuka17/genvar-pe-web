"""GenVar-PE · MVP web (Flask + PostgreSQL).

Permite ver el estado de la base, ejecutar las consultas C1–C8 con sus parámetros,
registrar datos con los procedimientos almacenados (y ver a los triggers en acción),
cambiar de rol para probar los permisos, y crear o borrar los índices para comparar tiempos.

Uso:
    pip install -r requirements.txt
    python app.py                      # http://localhost:5000
Variables de entorno opcionales:
    GENVAR_DSN   cadena de conexión de psycopg2 (por defecto "dbname=genvar")
"""
import os
import sys
import time
from contextlib import contextmanager

import psycopg2
import psycopg2.errors
import psycopg2.extras
from psycopg2 import sql
from flask import Flask, flash, redirect, render_template, request, session, url_for

AQUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(AQUI, "..", "exp"))
from consultas import CONSULTAS as CONSULTAS_EXP, INDICES_FINALES  # noqa: E402

# En la nube (Render + Neon) la conexión llega en DATABASE_URL; en la PC, en GENVAR_DSN.
DSN = os.environ.get("GENVAR_DSN") or os.environ.get("DATABASE_URL") or "dbname=genvar"
# Modo solo lectura para la versión pública: se puede ver todo, pero no modificar datos ni índices.
SOLO_LECTURA = os.environ.get("GENVAR_SOLO_LECTURA", "").lower() in ("1", "si", "sí", "true")
AVISO_SOLO_LECTURA = ("Esta es la versión pública en modo solo lectura: puedes ver y consultar todo, "
                      "pero registrar, modificar o cambiar índices está desactivado.")
MAX_FILAS = 200

app = Flask(__name__)
app.secret_key = os.environ.get("GENVAR_SECRET", "genvar-mvp")

ROLES = ["administrador", "tecnico_lab", "bioinformatico", "genetista", "investigador", "auditor"]

# ---------------------------------------------------------------------------
# Consultas: las 5 del experimento (misma fuente que el informe) + C4, C7 y C8
# ---------------------------------------------------------------------------
EXTRA = {
    "C4": dict(
        titulo="Control de calidad por laboratorio",
        descripcion=("Por laboratorio y secuenciador: corridas de los últimos 3 meses, cobertura media "
                     "promedio y porcentaje de muestras con cobertura < 30x o Q30 < 80 %."),
        sql="""SELECT l.nombre AS laboratorio, s.id_secuenciador,
       count(DISTINCT c.id_corrida)                                   AS corridas,
       round(avg(mc.cobertura_media), 1)                              AS cobertura_promedio,
       round(100.0 * avg((mc.cobertura_media < 30 OR mc.pct_q30 < 80)::int), 1)
                                                                      AS pct_muestras_deficientes
FROM laboratorio l
JOIN secuenciador s     ON s.id_laboratorio  = l.id_laboratorio
JOIN corrida c          ON c.id_secuenciador = s.id_secuenciador
JOIN muestra_corrida mc ON mc.id_corrida     = c.id_corrida
WHERE c.fecha_inicio >= %(hoy)s::date - interval '3 months'
GROUP BY l.nombre, s.id_secuenciador
ORDER BY pct_muestras_deficientes DESC"""),
    "C7": dict(
        titulo="Búsqueda por rs o por gen",
        descripcion="Dado un identificador rs o un símbolo de gen, devuelve las variantes con sus anotaciones.",
        sql="""SELECT v.id_variante, v.rsid, v.id_cromosoma, v.posicion, v.alelo_ref, v.alelo_alt,
       v.tipo_variante, ge.simbolo, vg.consecuencia, a.significancia, a.estado_revision
FROM v_variante v
LEFT JOIN variante_gen vg     ON vg.id_variante = v.id_variante
LEFT JOIN gen ge              ON ge.id_gen      = vg.id_gen
LEFT JOIN anotacion_clinica a ON a.id_variante  = v.id_variante
WHERE v.rsid = %(rs)s OR ge.simbolo = %(simbolo)s
ORDER BY v.id_cromosoma, v.posicion"""),
    "C8": dict(
        titulo="Reevaluación de donantes",
        descripcion=("Donantes con variantes reclasificadas de VUS a (probablemente) patogénica "
                     "después de su último informe."),
        sql="""SELECT DISTINCT m.id_donante, v.rsid, a.id_anotacion, h.significancia_nueva,
       h.fecha_cambio, ult.ultimo_informe
FROM anotacion_historial h
JOIN anotacion_clinica a ON a.id_anotacion = h.id_anotacion
JOIN variante v          ON v.id_variante  = a.id_variante
JOIN genotipo g          ON g.id_variante  = a.id_variante
JOIN muestra m           ON m.id_muestra   = g.id_muestra
JOIN (SELECT id_donante, max(fecha_informe) AS ultimo_informe
      FROM informe GROUP BY id_donante) ult ON ult.id_donante = m.id_donante
WHERE h.significancia_anterior = 'VUS'
  AND h.significancia_nueva IN ('PATOGENICA','PROBABLEMENTE_PATOGENICA')
  AND h.fecha_cambio > ult.ultimo_informe
ORDER BY m.id_donante, h.fecha_cambio"""),
}
CONSULTAS = {**CONSULTAS_EXP, **EXTRA}
CONSULTAS = {k: CONSULTAS[k] for k in sorted(CONSULTAS)}
EXPERIMENTO = list(CONSULTAS_EXP)          # C1, C2, C3, C5, C6

PARAMETROS = {   # nombre -> (etiqueta, valor por defecto)
    "donante": ("Donante", None),          # se completa con el donante con más hallazgos
    "crom": ("Cromosoma", "1"),
    "ini": ("Posición inicial", "1"),
    "fin": ("Posición final", "50000000"),
    "rs": ("Identificador rs", None),
    "simbolo": ("Símbolo de gen", None),
    "hoy": ("Fecha de referencia", "2026-10-01"),
}


def params_de(sql):
    return [p for p in PARAMETROS if f"%({p})s" in sql]


# ---------------------------------------------------------------------------
# Conexión
# ---------------------------------------------------------------------------
@contextmanager
def conexion(autocommit=True):
    con = psycopg2.connect(DSN)
    con.set_client_encoding("UTF8")        # acentos correctos aunque el servidor use otra codificación
    con.autocommit = autocommit
    try:
        cur = con.cursor(cursor_factory=psycopg2.extras.DictCursor)
        cur.execute("SET search_path TO genvar")
        rol = session.get("rol", "administrador")
        if rol != "administrador":
            cur.execute(f"SET ROLE {rol}")      # rol validado contra la lista ROLES
        yield con, cur
    finally:
        con.close()


def ejecutar(sql, params=None):
    """Devuelve (columnas, filas, ms, total) o lanza la excepción de PostgreSQL."""
    with conexion() as (con, cur):
        t0 = time.perf_counter()
        cur.execute(sql, params or {})
        filas = cur.fetchmany(MAX_FILAS) if cur.description else []
        total = cur.rowcount
        ms = (time.perf_counter() - t0) * 1000
        cols = [d.name for d in cur.description] if cur.description else []
        return cols, filas, ms, total


@app.context_processor
def globales():
    return dict(CONSULTAS=CONSULTAS, ROLES=ROLES, rol_actual=session.get("rol", "administrador"),
                SOLO_LECTURA=SOLO_LECTURA)


@app.route("/rol", methods=["POST"])
def cambiar_rol():
    rol = request.form.get("rol")
    if rol in ROLES:
        session["rol"] = rol
        flash(f"Ahora actúas como «{rol}».", "info")
    return redirect(request.referrer or url_for("inicio"))


# ---------------------------------------------------------------------------
# Páginas
# ---------------------------------------------------------------------------
@app.route("/")
def inicio():
    tablas = ["donante", "muestra", "corrida", "variante", "genotipo", "anotacion_clinica", "gen"]
    conteos, bitacora, significancia, poblacion, error = {}, [], [], [], None

    def leer(cur, sql):
        """Con autocommit cada sentencia es independiente: si el rol no tiene permiso se devuelve None."""
        try:
            cur.execute(sql)
            return cur.fetchall()
        except psycopg2.errors.InsufficientPrivilege:
            return None

    try:
        with conexion() as (con, cur):
            for t in tablas:
                r = leer(cur, f"SELECT count(*) FROM {t}")
                conteos[t] = r[0][0] if r else None
            significancia = leer(cur, """SELECT significancia, count(*) FROM anotacion_clinica GROUP BY 1
                           ORDER BY array_position(ARRAY['PATOGENICA','PROBABLEMENTE_PATOGENICA','VUS',
                                    'PROBABLEMENTE_BENIGNA','BENIGNA']::varchar[], significancia::varchar)""")
            poblacion = leer(cur, "SELECT poblacion, count(*) FROM donante GROUP BY 1 ORDER BY 2 DESC, 1")
            bitacora = leer(cur, "SELECT momento, usuario, evento, detalle FROM bitacora "
                                 "ORDER BY id_evento DESC LIMIT 8")
    except psycopg2.Error as e:
        error = e.pgerror or str(e)
    return render_template("inicio.html", conteos=conteos, bitacora=bitacora, error=error,
                           significancia=significancia, poblacion=poblacion)


def valores_por_defecto():
    """El donante con más hallazgos, y un rs y un gen que sí existen."""
    v = {k: d for k, (_, d) in PARAMETROS.items()}
    try:
        with conexion() as (con, cur):
            cur.execute("""SELECT id_donante FROM v_reporte_clinico
                           GROUP BY 1 ORDER BY count(*) DESC, 1 LIMIT 1""")
            r = cur.fetchone()
            v["donante"] = r[0] if r else "CGA-D000001"
            cur.execute("""SELECT v.rsid, ge.simbolo FROM anotacion_clinica a
                           JOIN variante v USING (id_variante)
                           JOIN variante_gen vg USING (id_variante) JOIN gen ge USING (id_gen)
                           WHERE v.rsid IS NOT NULL ORDER BY a.id_anotacion LIMIT 1""")
            r = cur.fetchone()
            v["rs"], v["simbolo"] = (r[0], r[1]) if r else ("rs1000010", "GV00010")
    except psycopg2.Error:
        v.update(donante="CGA-D000001", rs="rs1000010", simbolo="GV00010")
    return v


@app.route("/consulta/<cid>", methods=["GET", "POST"])
def consulta(cid):
    if cid not in CONSULTAS:
        return redirect(url_for("inicio"))
    info = CONSULTAS[cid]
    nombres = params_de(info["sql"])
    if "defaults" not in session:
        session["defaults"] = valores_por_defecto()
    valores = {p: request.form.get(p, session["defaults"].get(p)) for p in nombres}
    resultado, plan, error = None, None, None
    if request.method == "POST":
        try:
            cols, filas, ms, total = ejecutar(info["sql"], valores)
            resultado = dict(cols=cols, filas=filas, ms=ms, total=total)
            if request.form.get("plan"):
                _, pf, _, _ = ejecutar("EXPLAIN (ANALYZE, BUFFERS) " + info["sql"], valores)
                plan = "\n".join(r[0] for r in pf)
        except psycopg2.Error as e:
            error = e.pgerror or str(e)
    return render_template("consulta.html", cid=cid, info=info, nombres=nombres, valores=valores,
                           etiquetas={p: PARAMETROS[p][0] for p in nombres},
                           resultado=resultado, plan=plan, error=error,
                           en_experimento=cid in EXPERIMENTO, max_filas=MAX_FILAS)


@app.route("/donante", methods=["GET"])
def buscar_donante():
    d = request.args.get("id", "").strip()
    return redirect(url_for("donante", id_donante=d)) if d else redirect(url_for("inicio"))


@app.route("/donante/<id_donante>")
def donante(id_donante):
    datos, muestras, reporte, error = None, [], None, None
    try:
        with conexion() as (con, cur):
            cur.execute("SELECT * FROM donante WHERE id_donante = %s", (id_donante,))
            datos = cur.fetchone()
            cur.execute("""SELECT m.id_muestra, m.fecha_colecta, m.estado,
                                  CASE WHEN g.id_muestra IS NOT NULL THEN 'Germinal (' || g.fuente || ')'
                                       ELSE 'Tumoral (' || t.tipo_tumor || ')' END AS tipo,
                                  (SELECT string_agg(mc.id_corrida, ', ') FROM muestra_corrida mc
                                    WHERE mc.id_muestra = m.id_muestra) AS corridas
                           FROM muestra m
                           LEFT JOIN muestra_germinal g ON g.id_muestra = m.id_muestra
                           LEFT JOIN muestra_tumoral  t ON t.id_muestra = m.id_muestra
                           WHERE m.id_donante = %s ORDER BY m.fecha_colecta""", (id_donante,))
            muestras = cur.fetchall()
    except psycopg2.Error as e:
        error = e.pgerror or str(e)
    if datos is not None:
        try:
            cols, filas, ms, total = ejecutar("SELECT * FROM fn_reporte_clinico(%(d)s)", {"d": id_donante})
            reporte = dict(cols=cols, filas=filas, ms=ms, total=total)
        except psycopg2.Error as e:
            error = e.pgerror or str(e)
    return render_template("donante.html", id_donante=id_donante, datos=datos, muestras=muestras,
                           reporte=reporte, error=error)


# ---------------------------------------------------------------------------
# Explorar tablas: ver el contenido de cada tabla, con búsqueda y páginas
# ---------------------------------------------------------------------------
# nombre -> (título, grupo, ícono, descripción, columnas donde se busca)
# Una columna que empieza con "=" se compara por igualdad (rápido en tablas grandes).
TABLAS = {
    "donante":           ("Donantes", "Personas", "donante", "Personas que donaron muestras.", ["id_donante", "poblacion"]),
    "informe":           ("Informes", "Personas", "anotacion", "Informes clínicos entregados a cada donante.", ["id_donante", "genetista"]),
    "muestra":           ("Muestras", "Laboratorio", "muestra", "Muestras biológicas de cada donante.", ["id_muestra", "id_donante", "estado"]),
    "muestra_germinal":  ("Muestras germinales", "Laboratorio", "muestra", "Subclase: muestras de sangre, saliva o hisopado.", ["id_muestra", "fuente"]),
    "muestra_tumoral":   ("Muestras tumorales", "Laboratorio", "muestra", "Subclase: muestras de tumor.", ["id_muestra", "tipo_tumor"]),
    "laboratorio":       ("Laboratorios", "Laboratorio", "inicio", "Laboratorios del consorcio.", ["nombre", "ciudad"]),
    "secuenciador":      ("Secuenciadores", "Laboratorio", "corrida", "Equipos de secuenciación.", ["id_secuenciador", "modelo", "fabricante"]),
    "corrida":           ("Corridas", "Laboratorio", "corrida", "Corridas de secuenciación.", ["id_corrida", "id_secuenciador", "estado"]),
    "muestra_corrida":   ("Muestra por corrida", "Laboratorio", "filas", "Qué muestra entró en qué corrida, con su calidad.", ["id_muestra", "id_corrida"]),
    "cromosoma":         ("Cromosomas", "Genoma", "adn", "Cromosomas humanos.", ["id_cromosoma"]),
    "gen":               ("Genes", "Genoma", "gen", "Genes de referencia.", ["id_gen", "simbolo", "nombre"]),
    "exon":              ("Exones", "Genoma", "gen", "Exones de cada gen (entidad débil).", ["id_gen"]),
    "variante":          ("Variantes", "Genoma", "variante", "Variantes genéticas encontradas.", ["=id_variante", "rsid", "id_cromosoma"]),
    "variante_gen":      ("Variante por gen", "Genoma", "variante", "Gen afectado por cada variante y su consecuencia.", ["=id_variante", "id_gen", "consecuencia"]),
    "genotipo":          ("Genotipos", "Genoma", "genotipo", "El genotipo de cada muestra en cada variante (1 millón de filas). "
                                                            "Busca un código exacto de muestra, corrida o variante.",
                          ["=id_muestra", "=id_corrida", "=id_variante"]),
    "condicion":         ("Condiciones", "Clínica", "info", "Enfermedades o condiciones clínicas.", ["id_condicion", "nombre"]),
    "anotacion_clinica": ("Anotaciones clínicas", "Clínica", "anotacion", "Significancia clínica de cada variante.", ["id_anotacion", "=id_variante", "significancia"]),
    "anotacion_historial": ("Historial de anotaciones", "Clínica", "historial", "Reclasificaciones guardadas por el trigger T8.", ["id_anotacion"]),
    "bitacora":          ("Bitácora", "Clínica", "historial", "Eventos registrados por los triggers y las cargas.", ["evento", "detalle"]),
}
# columna -> tabla a la que lleva el enlace
ENLACES = {"id_muestra": "muestra", "id_corrida": "corrida", "id_variante": "variante", "id_gen": "gen",
           "id_anotacion": "anotacion_clinica", "id_condicion": "condicion", "id_secuenciador": "secuenciador",
           "id_laboratorio": "laboratorio", "id_cromosoma": "cromosoma"}
POR_PAGINA = 50
PREFIJOS = {"id_muestra": "CGA-M", "id_corrida": "RUN-", "id_donante": "CGA-D"}


@app.route("/tablas")
def tablas():
    return redirect(url_for("tabla", nombre="donante"))


@app.route("/tabla/<nombre>")
def tabla(nombre):
    if nombre not in TABLAS:
        return redirect(url_for("tabla", nombre="donante"))
    titulo, grupo, icono, descripcion, buscables = TABLAS[nombre]
    q = request.args.get("q", "").strip()
    pagina = max(1, request.args.get("pag", 1, type=int))
    cols, filas, total, ms, error = [], [], 0, 0.0, None
    try:
        with conexion() as (con, cur):
            cur.execute("""SELECT a.attname FROM pg_index i
                           JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
                           WHERE i.indrelid = %s::regclass AND i.indisprimary
                           ORDER BY array_position(i.indkey::int2[], a.attnum)""", (f"genvar.{nombre}",))
            pk = [r[0] for r in cur.fetchall()] or None
            where, params = sql.SQL(""), {}
            if q:
                conds = []
                params = {"q": q, "qlike": f"%{q}%", "qnum": int(q) if q.isdigit() else None}
                for c in buscables:
                    if c == "=id_variante":           # columna numérica: solo si se escribió un número
                        if q.isdigit():
                            conds.append(sql.SQL("id_variante = %(qnum)s"))
                    elif c.startswith("="):
                        # en tablas grandes solo se busca en la columna cuyo formato coincide con el código
                        prefijo = PREFIJOS.get(c[1:])
                        if prefijo is None or q.upper().startswith(prefijo):
                            conds.append(sql.SQL("{} = %(q)s").format(sql.Identifier(c[1:])))
                    else:
                        conds.append(sql.SQL("{}::text ILIKE %(qlike)s").format(sql.Identifier(c)))
                where = sql.SQL(" WHERE ") + (sql.SQL(" OR ").join(conds) if conds else sql.SQL("false"))
            t0 = time.perf_counter()
            cur.execute(sql.SQL("SELECT count(*) FROM {}").format(sql.Identifier(nombre)) + where, params)
            total = cur.fetchone()[0]
            orden = sql.SQL(", ").join(map(sql.Identifier, pk)) if pk else sql.SQL("1")
            cur.execute(sql.SQL("SELECT * FROM {}").format(sql.Identifier(nombre)) + where
                        + sql.SQL(" ORDER BY ") + orden + sql.SQL(" LIMIT %(lim)s OFFSET %(off)s"),
                        {**params, "lim": POR_PAGINA, "off": (pagina - 1) * POR_PAGINA})
            filas = cur.fetchall()
            cols = [d.name for d in cur.description]
            ms = (time.perf_counter() - t0) * 1000
    except psycopg2.errors.InsufficientPrivilege:
        error = f"El rol «{session.get('rol', 'administrador')}» no tiene permiso para ver la tabla {nombre}."
    except psycopg2.Error as e:
        error = e.pgerror or str(e)
    paginas = max(1, -(-total // POR_PAGINA))
    grupos = {}
    for t, (tt, g, ic, _, _) in TABLAS.items():
        grupos.setdefault(g, []).append((t, tt, ic))
    return render_template("tabla.html", nombre=nombre, titulo=titulo, ico=icono, descripcion=descripcion,
                           buscables=[c.lstrip("=") for c in buscables], q=q, pagina=pagina, paginas=paginas,
                           cols=cols, filas=filas, total=total, ms=ms, error=error, grupos=grupos,
                           enlaces=ENLACES, por_pagina=POR_PAGINA)


# ---------------------------------------------------------------------------
# Operaciones (procedimientos almacenados y triggers)
# ---------------------------------------------------------------------------
OPERACIONES = {
    "donante": ("INSERT INTO donante VALUES (%(id_donante)s, %(sexo)s, %(anio)s, %(poblacion)s, %(consentimiento)s)",
                "Donante {id_donante} registrado."),
    "muestra": ("CALL sp_registrar_muestra(%(id_muestra)s, %(id_donante)s, %(fecha)s, %(conc)s, %(tipo)s, "
                "%(fuente)s, %(tipo_tumor)s, %(estadio)s, %(pureza)s)",
                "Muestra {id_muestra} registrada para {id_donante}."),
    "reclasificar": ("CALL sp_reclasificar_anotacion(%(id_anotacion)s, %(nueva)s, %(fecha)s)",
                     "Anotación {id_anotacion} reclasificada a {nueva}; el trigger T8 guardó el historial."),
    "revocar": ("CALL sp_revocar_consentimiento(%(id_donante)s)",
                "Consentimiento de {id_donante} revocado; el trigger T9 borró sus muestras y genotipos."),
}


@app.route("/operaciones", methods=["GET", "POST"])
def operaciones():
    if request.method == "POST" and SOLO_LECTURA:
        flash(AVISO_SOLO_LECTURA, "info")
        return redirect(url_for("operaciones"))
    if request.method == "POST":
        op = request.form.get("op")
        if op in OPERACIONES:
            sql, ok = OPERACIONES[op]
            p = {k: (v.strip() or None) for k, v in request.form.items()}
            if op == "donante":
                p["consentimiento"] = request.form.get("consentimiento") == "si"
            try:
                with conexion(autocommit=False) as (con, cur):
                    cur.execute(sql, p)
                    con.commit()     # el trigger diferido T5 se revisa aquí
                flash(ok.format(**p), "ok")
            except psycopg2.Error as e:
                flash("PostgreSQL rechazó la operación: " + (e.diag.message_primary or str(e)), "error")
        return redirect(url_for("operaciones") + f"#{op}")
    historial, bitacora = [], []
    try:
        with conexion() as (con, cur):
            cur.execute("""SELECT h.id_anotacion, h.significancia_anterior, h.significancia_nueva, h.fecha_cambio
                           FROM anotacion_historial h ORDER BY h.id_cambio DESC LIMIT 5""")
            historial = cur.fetchall()
            cur.execute("SELECT momento, evento, detalle FROM bitacora ORDER BY id_evento DESC LIMIT 5")
            bitacora = cur.fetchall()
    except psycopg2.Error:
        pass
    return render_template("operaciones.html", historial=historial, bitacora=bitacora)


# ---------------------------------------------------------------------------
# Índices: crear / borrar y comparar tiempos de las 5 consultas del experimento
# ---------------------------------------------------------------------------
@app.route("/indices", methods=["GET", "POST"])
def indices():
    if request.method == "POST" and SOLO_LECTURA and request.form.get("accion") in ("crear", "borrar"):
        flash(AVISO_SOLO_LECTURA, "info")
        return redirect(url_for("indices"))
    if request.method == "POST":
        accion = request.form.get("accion")
        try:
            with conexion() as (con, cur):
                t0 = time.perf_counter()
                if accion == "crear":
                    for ddl in INDICES_FINALES:
                        cur.execute(ddl)
                    cur.execute("ANALYZE")
                    flash(f"Índices finales creados en {time.perf_counter() - t0:.1f} s.", "ok")
                elif accion == "borrar":
                    cur.execute("""SELECT indexname FROM pg_indexes
                                   WHERE schemaname = 'genvar' AND indexname LIKE 'ix\\_%%'""")
                    for (ix,) in cur.fetchall():
                        cur.execute(f"DROP INDEX genvar.{ix}")
                    cur.execute("ANALYZE")
                    flash("Índices del experimento borrados (quedan solo los de PK y UNIQUE).", "ok")
                elif accion == "medir":
                    if "defaults" not in session:
                        session["defaults"] = valores_por_defecto()
                    tiempos = []
                    for q in EXPERIMENTO:
                        sql = CONSULTAS[q]["sql"]
                        vals = {p: session["defaults"].get(p) for p in params_de(sql)}
                        cur.execute("EXPLAIN (ANALYZE, FORMAT JSON) " + sql, vals)   # calentamiento
                        ts = []
                        for _ in range(3):
                            cur.execute("EXPLAIN (ANALYZE, FORMAT JSON) " + sql, vals)
                            ts.append(cur.fetchone()[0][0]["Execution Time"])
                        tiempos.append((q, sorted(ts)[1]))
                    cur.execute("""SELECT count(*) FROM pg_indexes
                                   WHERE schemaname = 'genvar' AND indexname LIKE 'ix\\_%%'""")
                    n_ix = cur.fetchone()[0]
                    etiqueta = "con índices" if n_ix else "sin índices"
                    session.setdefault("mediciones", {})
                    med = session["mediciones"]
                    med[etiqueta] = dict(tiempos)
                    session["mediciones"] = med
                    flash(f"Medición guardada como «{etiqueta}».", "ok")
        except psycopg2.Error as e:
            flash("PostgreSQL rechazó la operación: " + (e.diag.message_primary or str(e)), "error")
        return redirect(url_for("indices"))
    lista, error = [], None
    try:
        with conexion() as (con, cur):
            cur.execute("""SELECT i.indexrelname AS indice, i.relname AS tabla,
                                  pg_size_pretty(pg_relation_size(i.indexrelid)) AS tamano,
                                  i.indexrelname LIKE 'ix\\_%%' AS del_experimento,
                                  pg_get_indexdef(i.indexrelid) AS definicion
                           FROM pg_stat_user_indexes i WHERE i.schemaname = 'genvar'
                           ORDER BY del_experimento DESC, pg_relation_size(i.indexrelid) DESC""")
            lista = cur.fetchall()
    except psycopg2.Error as e:
        error = e.pgerror or str(e)
    return render_template("indices.html", lista=lista, error=error,
                           mediciones=session.get("mediciones", {}), experimento=EXPERIMENTO)


@app.route("/indices/limpiar", methods=["POST"])
def limpiar_mediciones():
    session.pop("mediciones", None)
    return redirect(url_for("indices"))


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 5000)), debug=False)
