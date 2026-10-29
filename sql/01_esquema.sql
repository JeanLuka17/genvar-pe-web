-- =====================================================================
-- GenVar-PE · Hito 2 · 4.1 Creación de tablas en PostgreSQL
-- Esquema fiel al modelo relacional y al diccionario de datos del Hito 1.
-- Uso:  psql -d genvar -f 01_esquema.sql
-- =====================================================================
DROP SCHEMA IF EXISTS genvar CASCADE;
CREATE SCHEMA genvar;
SET search_path TO genvar;

-- ---------- Catálogo de referencia ----------
CREATE TABLE cromosoma (
    id_cromosoma  VARCHAR(2)  PRIMARY KEY,
    longitud_pb   BIGINT      NOT NULL CHECK (longitud_pb > 0),
    tipo          VARCHAR(12) NOT NULL CHECK (tipo IN ('AUTOSOMA','SEXUAL','MITOCONDRIAL'))
);

CREATE TABLE gen (
    id_gen        VARCHAR(20)  PRIMARY KEY,
    simbolo       VARCHAR(30)  NOT NULL UNIQUE,
    nombre        VARCHAR(200),
    biotipo       VARCHAR(40)  NOT NULL,
    id_cromosoma  VARCHAR(2)   NOT NULL REFERENCES cromosoma,
    inicio        BIGINT       NOT NULL CHECK (inicio >= 1),
    fin           BIGINT       NOT NULL,
    hebra         CHAR(1)      NOT NULL CHECK (hebra IN ('+','-')),
    CHECK (inicio <= fin)
);

-- Entidad débil: llave = llave del gen + llave parcial numero_exon
CREATE TABLE exon (
    id_gen        VARCHAR(20) REFERENCES gen ON DELETE CASCADE,
    numero_exon   SMALLINT    CHECK (numero_exon >= 1),
    inicio        BIGINT      NOT NULL,
    fin           BIGINT      NOT NULL,
    PRIMARY KEY (id_gen, numero_exon),
    CHECK (inicio <= fin)
);

CREATE TABLE variante (
    id_variante      BIGSERIAL    PRIMARY KEY,
    rsid             VARCHAR(15)  UNIQUE,
    id_cromosoma     VARCHAR(2)   NOT NULL REFERENCES cromosoma,
    posicion         BIGINT       NOT NULL CHECK (posicion >= 1),
    alelo_ref        VARCHAR(50)  NOT NULL CHECK (alelo_ref ~ '^[ACGT]+$'),
    alelo_alt        VARCHAR(50)  NOT NULL CHECK (alelo_alt ~ '^[ACGT]+$'),
    frec_poblacional NUMERIC(8,7) CHECK (frec_poblacional BETWEEN 0 AND 1),
    CHECK (alelo_ref <> alelo_alt),
    UNIQUE (id_cromosoma, posicion, alelo_ref, alelo_alt)      -- llave natural (RS13)
);

CREATE TABLE variante_gen (
    id_variante   BIGINT      REFERENCES variante ON DELETE CASCADE,
    id_gen        VARCHAR(20) REFERENCES gen ON DELETE CASCADE,
    consecuencia  VARCHAR(40) NOT NULL,
    impacto       VARCHAR(11) NOT NULL CHECK (impacto IN ('ALTO','MODERADO','BAJO','MODIFICADOR')),
    PRIMARY KEY (id_variante, id_gen)
);

CREATE TABLE condicion (
    id_condicion  VARCHAR(20)  PRIMARY KEY,
    nombre        VARCHAR(200) NOT NULL,
    modo_herencia VARCHAR(30)
);

CREATE TABLE anotacion_clinica (
    id_anotacion     VARCHAR(20) PRIMARY KEY,
    id_variante      BIGINT      NOT NULL REFERENCES variante ON DELETE CASCADE,
    id_condicion     VARCHAR(20) NOT NULL REFERENCES condicion,
    significancia    VARCHAR(26) NOT NULL CHECK (significancia IN
        ('PATOGENICA','PROBABLEMENTE_PATOGENICA','VUS','PROBABLEMENTE_BENIGNA','BENIGNA')),
    estado_revision  SMALLINT    NOT NULL CHECK (estado_revision BETWEEN 0 AND 4),
    fecha_evaluacion DATE
);

-- ---------- Donantes y muestras ----------
CREATE TABLE donante (
    id_donante      VARCHAR(12) PRIMARY KEY,
    sexo            CHAR(1)     NOT NULL CHECK (sexo IN ('F','M','X')),
    anio_nacimiento SMALLINT    CHECK (anio_nacimiento BETWEEN 1900 AND EXTRACT(YEAR FROM CURRENT_DATE)),
    poblacion       VARCHAR(40),
    consentimiento  BOOLEAN     NOT NULL
);

CREATE TABLE muestra (
    id_muestra    VARCHAR(14)  PRIMARY KEY,
    id_donante    VARCHAR(12)  NOT NULL REFERENCES donante ON DELETE CASCADE,
    fecha_colecta DATE         NOT NULL,
    conc_adn      NUMERIC(7,2) CHECK (conc_adn > 0),
    estado        VARCHAR(12)  NOT NULL CHECK (estado IN ('RECIBIDA','EN_PROCESO','SECUENCIADA','DESCARTADA'))
);

-- Is-A "tabla por clase": cada subclase guarda la llave de Muestra y sus atributos propios
CREATE TABLE muestra_germinal (
    id_muestra VARCHAR(14) PRIMARY KEY REFERENCES muestra ON DELETE CASCADE,
    fuente     VARCHAR(15) NOT NULL CHECK (fuente IN ('SANGRE','SALIVA','HISOPADO_BUCAL'))
);

CREATE TABLE muestra_tumoral (
    id_muestra     VARCHAR(14)  PRIMARY KEY REFERENCES muestra ON DELETE CASCADE,
    tipo_tumor     VARCHAR(60)  NOT NULL,
    estadio        VARCHAR(5),
    pureza_tumoral NUMERIC(5,2) CHECK (pureza_tumoral BETWEEN 0 AND 100)
);

-- ---------- Laboratorios y secuenciación ----------
CREATE TABLE laboratorio (
    id_laboratorio SERIAL      PRIMARY KEY,
    nombre         VARCHAR(80) NOT NULL UNIQUE,
    ciudad         VARCHAR(40) NOT NULL,
    pais           VARCHAR(40) NOT NULL
);

CREATE TABLE secuenciador (
    id_secuenciador VARCHAR(20) PRIMARY KEY,
    id_laboratorio  INTEGER     NOT NULL REFERENCES laboratorio,
    modelo          VARCHAR(40) NOT NULL,
    fabricante      VARCHAR(40) NOT NULL,
    tecnologia      VARCHAR(14) NOT NULL CHECK (tecnologia IN ('LECTURA_CORTA','LECTURA_LARGA'))
);

CREATE TABLE corrida (
    id_corrida      VARCHAR(30)  PRIMARY KEY,
    id_secuenciador VARCHAR(20)  NOT NULL REFERENCES secuenciador,
    tipo_ensayo     VARCHAR(5)   NOT NULL CHECK (tipo_ensayo IN ('WGS','WES','PANEL')),
    fecha_inicio    TIMESTAMP    NOT NULL,
    fecha_fin       TIMESTAMP,
    estado          VARCHAR(12)  NOT NULL CHECK (estado IN ('EN_CURSO','COMPLETADA','FALLIDA')),
    rendimiento_gb  NUMERIC(8,2) CHECK (rendimiento_gb >= 0),
    CHECK (fecha_fin IS NULL OR fecha_fin >= fecha_inicio)                 -- RS9
);

CREATE TABLE muestra_corrida (
    id_muestra       VARCHAR(14)  REFERENCES muestra ON DELETE CASCADE,
    id_corrida       VARCHAR(30)  REFERENCES corrida,
    barcode          VARCHAR(20)  NOT NULL,
    lecturas_totales BIGINT       CHECK (lecturas_totales >= 0),
    cobertura_media  NUMERIC(7,2) CHECK (cobertura_media >= 0),
    pct_q30          NUMERIC(5,2) CHECK (pct_q30 BETWEEN 0 AND 100),
    PRIMARY KEY (id_muestra, id_corrida),
    UNIQUE (id_corrida, barcode)                                           -- RS8
);

-- Relación ternaria Detecta. La FK compuesta a muestra_corrida impone RS19.
CREATE TABLE genotipo (
    id_muestra  VARCHAR(14),
    id_corrida  VARCHAR(30),
    id_variante BIGINT       NOT NULL REFERENCES variante,
    genotipo    VARCHAR(3)   NOT NULL CHECK (genotipo IN ('0/1','1/1')),
    profundidad INTEGER      NOT NULL CHECK (profundidad > 0),
    calidad     REAL         CHECK (calidad >= 0),
    vaf         NUMERIC(4,3) CHECK (vaf BETWEEN 0 AND 1),
    filtro      VARCHAR(20)  NOT NULL,
    PRIMARY KEY (id_muestra, id_corrida, id_variante),
    FOREIGN KEY (id_muestra, id_corrida) REFERENCES muestra_corrida ON DELETE CASCADE
);

-- ---------- Tablas agregadas en el Hito 2 (decisiones de implementación) ----------
-- Informes clínicos emitidos: necesarios para la consulta C8 (reevaluación).
CREATE TABLE informe (
    id_informe    SERIAL      PRIMARY KEY,
    id_donante    VARCHAR(12) NOT NULL REFERENCES donante ON DELETE CASCADE,
    fecha_informe DATE        NOT NULL,
    genetista     VARCHAR(60) NOT NULL
);

-- Historial de reclasificaciones de anotaciones (lo llena un trigger).
CREATE TABLE anotacion_historial (
    id_cambio              BIGSERIAL   PRIMARY KEY,
    id_anotacion           VARCHAR(20) NOT NULL REFERENCES anotacion_clinica ON DELETE CASCADE,
    significancia_anterior VARCHAR(26) NOT NULL,
    significancia_nueva    VARCHAR(26) NOT NULL,
    fecha_cambio           DATE        NOT NULL
);

-- Bitácora de auditoría (revocaciones de consentimiento y cargas de genotipos).
CREATE TABLE bitacora (
    id_evento   BIGSERIAL   PRIMARY KEY,
    momento     TIMESTAMP   NOT NULL DEFAULT now(),
    usuario     TEXT        NOT NULL DEFAULT current_user,
    evento      VARCHAR(30) NOT NULL,
    detalle     TEXT
);
