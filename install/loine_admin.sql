/*
 Loine – administration of the installations in a database (complete deliveries)

 SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-casaGeo-Commercial
 Copyright © 2026 casaGeo Data + Services GmbH – https://www.casageo.de/loine.html – info@casageo.de

 Run once per database and again with every new LOINE version (repeatable):
     psql -d <database> -f loine_admin.sql

 A complete delivery is one dump with all ordered countries in its own schema pgr_YYYYMMDD (e.g. pgr_20261124,
 a second delivery on the same day pgr_20261124_2). It is installed next to the running installation pgr, tested
 under its own name and then switched to pgr:

     pg_restore -d <database> --no-owner -j 4 loine_pgr_20261124_….dump     -- creates schema pgr_20261124
     -- install the functions into the schema (loine_functions.sql with "pgr." replaced by "pgr_20261124.")
     SELECT * FROM loine_admin.installations();
     CALL loine_admin.switch_installation('pgr_20261124');                   -- old pgr is kept as pgr_<date>
     CALL loine_admin.switch_installation('pgr_20261124', p_old => 'drop'); -- old pgr is dropped
     CALL loine_admin.switch_installation('pgr_20250510');                   -- switch back
     CALL loine_admin.drop_installation('pgr_20250510');

 The routing functions name their schema in the function body (pgr.…). Tables, indexes and partitions follow a
 rename through their OIDs, the functions do not. switch_installation therefore rewrites the function bodies of both
 installations (pgr. → pgr_<date>. and pgr_<new>. → pgr.), so that each installation keeps using its own data.
 Everything runs in one transaction. Views of the customer follow the OIDs and keep pointing to the OLD installation;
 own functions with a text body point to the NEW one (they name pgr.). loine_admin.dependents() lists the views and
 other objects that depend on an installation.

 After switching, sessions that used LOINE should reconnect (cached plans of PL/pgSQL refer to OIDs);
 loine_admin.terminate_sessions() disconnects the other sessions of the database.

 Requirements: PostgreSQL 18, PostGIS, pgRouting. The user who switches must own both schemas and their functions.
 */

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pgrouting;
CREATE SCHEMA IF NOT EXISTS loine_admin;

-- Projections of the regions outside Europe (Lambert azimuthal equal area per continent), as in loine_install.sql
INSERT INTO spatial_ref_sys (srid, auth_name, auth_srid, proj4text, srtext)
VALUES (990001, 'LOINE', 990001,
        '+proj=laea +lat_0=4.2 +lon_0=19.1 +x_0=5500000 +y_0=5500000 +datum=WGS84 +units=m +no_defs',
        'PROJCS["LOINE Afrika LAEA",GEOGCS["WGS 84",DATUM["WGS_1984",SPHEROID["WGS 84",6378137,298.257223563,AUTHORITY["EPSG","7030"]],AUTHORITY["EPSG","6326"]],PRIMEM["Greenwich",0,AUTHORITY["EPSG","8901"]],UNIT["degree",0.0174532925199433,AUTHORITY["EPSG","9122"]]],PROJECTION["Lambert_Azimuthal_Equal_Area"],PARAMETER["latitude_of_center",4.2],PARAMETER["longitude_of_center",19.1],PARAMETER["false_easting",5500000],PARAMETER["false_northing",5500000],UNIT["metre",1,AUTHORITY["EPSG","9001"]],AXIS["Easting",EAST],AXIS["Northing",NORTH]]'),
       (990002, 'LOINE', 990002,
        '+proj=laea +lat_0=43.3 +lon_0=-94 +x_0=5500000 +y_0=5500000 +datum=WGS84 +units=m +no_defs',
        'PROJCS["LOINE Nordamerika LAEA",GEOGCS["WGS 84",DATUM["WGS_1984",SPHEROID["WGS 84",6378137,298.257223563,AUTHORITY["EPSG","7030"]],AUTHORITY["EPSG","6326"]],PRIMEM["Greenwich",0,AUTHORITY["EPSG","8901"]],UNIT["degree",0.0174532925199433,AUTHORITY["EPSG","9122"]]],PROJECTION["Lambert_Azimuthal_Equal_Area"],PARAMETER["latitude_of_center",43.3],PARAMETER["longitude_of_center",-94],PARAMETER["false_easting",5500000],PARAMETER["false_northing",5500000],UNIT["metre",1,AUTHORITY["EPSG","9001"]],AXIS["Easting",EAST],AXIS["Northing",NORTH]]')
ON CONFLICT (srid) DO UPDATE SET auth_name = EXCLUDED.auth_name,
                                 auth_srid = EXCLUDED.auth_srid,
                                 proj4text = EXCLUDED.proj4text,
                                 srtext    = EXCLUDED.srtext;

-- Which installation was active when, and what happened to the old one
CREATE TABLE IF NOT EXISTS loine_admin.installation_history
(
    id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    schema_name   TEXT        NOT NULL,                -- name after the action
    action        TEXT        NOT NULL CHECK (action IN ('activated', 'kept_as', 'dropped')),
    delivery_date DATE,
    loine_version TEXT,
    countries     TEXT[],
    changed_at    TIMESTAMPTZ NOT NULL DEFAULT CLOCK_TIMESTAMP(),
    db_user       TEXT        NOT NULL DEFAULT CURRENT_USER,
    note          TEXT
);

--======================================================================================================================
-- Helpers
--======================================================================================================================

-- Names of LOINE installations: pgr (active) and pgr_YYYYMMDD[_n]
CREATE OR REPLACE FUNCTION loine_admin._is_installation_name(p_schema TEXT)
    RETURNS BOOLEAN
    LANGUAGE sql
    IMMUTABLE
AS
$$
SELECT p_schema ~ '^pgr(_[0-9]{8}(_[0-9]+)?)?$';
$$;

-- Schema of an object from pg_depend (classid, objid); NULL if the object has no schema
CREATE OR REPLACE FUNCTION loine_admin._object_schema(p_classid OID, p_objid OID)
    RETURNS OID
    LANGUAGE sql
    STABLE
AS
$$
SELECT CASE p_classid
           WHEN 'pg_class'::REGCLASS THEN (SELECT relnamespace FROM pg_class WHERE oid = p_objid)
           WHEN 'pg_proc'::REGCLASS THEN (SELECT pronamespace FROM pg_proc WHERE oid = p_objid)
           WHEN 'pg_type'::REGCLASS THEN (SELECT typnamespace FROM pg_type WHERE oid = p_objid)
           WHEN 'pg_constraint'::REGCLASS THEN (SELECT connamespace FROM pg_constraint WHERE oid = p_objid)
           WHEN 'pg_rewrite'::REGCLASS THEN (SELECT c.relnamespace
                                             FROM pg_rewrite r JOIN pg_class c ON c.oid = r.ev_class
                                             WHERE r.oid = p_objid)
           WHEN 'pg_trigger'::REGCLASS THEN (SELECT c.relnamespace
                                             FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
                                             WHERE t.oid = p_objid)
           WHEN 'pg_attrdef'::REGCLASS THEN (SELECT c.relnamespace
                                             FROM pg_attrdef a JOIN pg_class c ON c.oid = a.adrelid
                                             WHERE a.oid = p_objid)
           WHEN 'pg_policy'::REGCLASS THEN (SELECT c.relnamespace
                                            FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
                                            WHERE p.oid = p_objid)
           END;
$$;

-- Value of a single row/column query in a schema that may not have the table/function; NULL on error
CREATE OR REPLACE FUNCTION loine_admin._try(p_sql TEXT)
    RETURNS TEXT
    LANGUAGE plpgsql
    STABLE
AS
$$
DECLARE
    v TEXT;
BEGIN
    EXECUTE p_sql INTO v;
    RETURN v;
EXCEPTION
    WHEN OTHERS THEN
        RETURN NULL;
END;
$$;

--======================================================================================================================
-- Installations in this database
--======================================================================================================================
CREATE OR REPLACE FUNCTION loine_admin.installations()
    RETURNS TABLE
            (
                schema_name   TEXT,
                active        BOOLEAN,
                delivery_date DATE,
                source        TEXT,
                region        TEXT,
                srid          INTEGER,
                countries     TEXT,
                loine_version TEXT,
                functions     BOOLEAN,
                net_level     BOOLEAN,
                size_bytes    BIGINT,
                legacy        BOOLEAN   -- installed with the old per-country procedure (no loine_delivery)
            )
    LANGUAGE plpgsql
    STABLE
AS
$$
DECLARE
    s TEXT;
BEGIN
    FOR s IN
        SELECT n.nspname
        FROM pg_namespace n
        WHERE loine_admin._is_installation_name(n.nspname)
          AND TO_REGCLASS(FORMAT('%I.loine_installed', n.nspname)) IS NOT NULL
        ORDER BY n.nspname = 'pgr' DESC, n.nspname DESC
        LOOP
            schema_name := s;
            active := (s = 'pgr');
            legacy := TO_REGCLASS(FORMAT('%I.loine_delivery', s)) IS NULL;
            IF legacy THEN
                delivery_date := loine_admin._try(FORMAT('SELECT MAX(installed_at)::DATE FROM %I.loine_installed', s))::DATE;
            ELSE
                delivery_date := loine_admin._try(FORMAT('SELECT delivery_date FROM %I.loine_delivery', s))::DATE;
            END IF;
            source := loine_admin._try(FORMAT('SELECT STRING_AGG(DISTINCT source, '', '') FROM %I.loine_installed', s));
            region := loine_admin._try(FORMAT('SELECT STRING_AGG(DISTINCT region, '', '') FROM %I.loine_installed', s));
            srid := loine_admin._try(FORMAT('SELECT MIN(srid) FROM %I.loine_installed', s))::INTEGER;
            countries := loine_admin._try(FORMAT('SELECT STRING_AGG(UPPER(country), '', '' ORDER BY country) FROM %I.loine_installed', s));
            functions := TO_REGPROCEDURE(FORMAT('%I.loine_info()', s)) IS NOT NULL;
            loine_version := CASE WHEN functions
                                      THEN loine_admin._try(FORMAT('SELECT (%I.loine_info()).version', s)) END;
            net_level := COALESCE(loine_admin._try(FORMAT('SELECT count(*) > 0 FROM %I.net_level', s))::BOOLEAN, FALSE);
            size_bytes := (SELECT COALESCE(SUM(PG_TOTAL_RELATION_SIZE(c.oid)), 0)
                           FROM pg_class c
                           WHERE c.relnamespace = s::REGNAMESPACE
                             AND c.relkind IN ('r', 'm'));
            RETURN NEXT;
        END LOOP;
END;
$$;

--======================================================================================================================
-- Objects outside the LOINE installations that depend on objects of an installation (e.g. views of the customer).
-- Objects whose function body names the schema as text are not found (they have no entry in pg_depend).
--======================================================================================================================
CREATE OR REPLACE FUNCTION loine_admin.dependents(p_schema TEXT)
    RETURNS TABLE
            (
                object_schema TEXT,
                object        TEXT,
                depends_on    TEXT
            )
    LANGUAGE sql
    STABLE
AS
$$
WITH ref AS (SELECT 'pg_class'::REGCLASS AS cls, c.oid FROM pg_class c WHERE c.relnamespace = TO_REGNAMESPACE(p_schema)
             UNION ALL
             SELECT 'pg_proc'::REGCLASS, p.oid FROM pg_proc p WHERE p.pronamespace = TO_REGNAMESPACE(p_schema)
             UNION ALL
             SELECT 'pg_type'::REGCLASS, t.oid FROM pg_type t WHERE t.typnamespace = TO_REGNAMESPACE(p_schema)),
     dep AS (SELECT d.classid, d.objid, d.refclassid, d.refobjid,
                    loine_admin._object_schema(d.classid, d.objid) AS nsp
             FROM pg_depend d
                      JOIN ref ON ref.cls = d.refclassid AND ref.oid = d.refobjid
             WHERE d.deptype IN ('n', 'a'))
SELECT DISTINCT n.nspname::TEXT,
                CASE WHEN dep.classid = 'pg_rewrite'::REGCLASS
                         THEN (SELECT PG_DESCRIBE_OBJECT('pg_class'::REGCLASS, r.ev_class, 0)
                               FROM pg_rewrite r WHERE r.oid = dep.objid)
                     ELSE PG_DESCRIBE_OBJECT(dep.classid, dep.objid, 0) END,
                PG_DESCRIBE_OBJECT(dep.refclassid, dep.refobjid, 0)
FROM dep
         JOIN pg_namespace n ON n.oid = dep.nsp
WHERE NOT loine_admin._is_installation_name(n.nspname)
ORDER BY 1, 2, 3;
$$;

--======================================================================================================================
-- Street categories that differ between two installations (for display before switching; nothing is copied)
--======================================================================================================================
CREATE OR REPLACE FUNCTION loine_admin.mode_category_diff(p_a TEXT, p_b TEXT)
    RETURNS TABLE
            (
                source TEXT,
                mode   TEXT,
                kind   TEXT,
                cats_a INTEGER[],
                cats_b INTEGER[]
            )
    LANGUAGE plpgsql
    STABLE
AS
$$
BEGIN
    IF TO_REGCLASS(FORMAT('%I.loine_mode_category', p_a)) IS NULL
        OR TO_REGCLASS(FORMAT('%I.loine_mode_category', p_b)) IS NULL THEN
        RETURN;
    END IF;
    RETURN QUERY EXECUTE FORMAT(
            'SELECT COALESCE(a.source, b.source), COALESCE(a.mode, b.mode), k.kind, k.ca, k.cb
             FROM %I.loine_mode_category a
                      FULL JOIN %I.loine_mode_category b ON b.source = a.source AND b.mode = a.mode
                      CROSS JOIN LATERAL (VALUES (''buffer'', a.buffer_cats, b.buffer_cats),
                                                 (''main'', a.main_cats, b.main_cats),
                                                 (''snap'', a.snap_cats, b.snap_cats),
                                                 (''matrix'', a.matrix_cats, b.matrix_cats)) AS k(kind, ca, cb)
             WHERE k.ca IS DISTINCT FROM k.cb
             ORDER BY 1, 2, 3', p_a, p_b);
END;
$$;

--======================================================================================================================
-- Quick check of an installation before (or after) switching: functions, projection, row counts against the delivery,
-- indexes, base network and a test route. Counting all rows takes up to a minute for large deliveries.
-- status: ok | warning | error
--======================================================================================================================
CREATE OR REPLACE FUNCTION loine_admin.check_installation(p_schema TEXT)
    RETURNS TABLE
            (
                check_name TEXT,
                status     TEXT,
                detail     TEXT
            )
    LANGUAGE plpgsql
    VOLATILE
AS
$$
DECLARE
    v_ver     TEXT;
    v_srid    INTEGER;
    v_inst    INTEGER;
    v_n       BIGINT;
    v_exp     BIGINT;
    v_txt     TEXT;
    v_tile    TEXT;
    a         RECORD;
    b         RECORD;
    v_route   RECORD;
    v_deliv   BOOLEAN;
    v_area    GEOMETRY;
BEGIN
    IF NOT loine_admin._is_installation_name(p_schema) OR TO_REGNAMESPACE(p_schema) IS NULL
        OR TO_REGCLASS(FORMAT('%I.loine_installed', p_schema)) IS NULL THEN
        check_name := 'installation'; status := 'error';
        detail := FORMAT('%s is not a LOINE installation', p_schema);
        RETURN NEXT;
        RETURN;
    END IF;
    v_deliv := TO_REGCLASS(FORMAT('%I.loine_delivery', p_schema)) IS NOT NULL;

    -- functions
    check_name := 'functions';
    IF TO_REGPROCEDURE(FORMAT('%I.loine_info()', p_schema)) IS NULL THEN
        status := 'error'; detail := 'not installed';
        RETURN NEXT;
        RETURN;
    END IF;
    EXECUTE FORMAT('SELECT (%I.loine_info()).version', p_schema) INTO v_ver;
    status := 'ok'; detail := 'LOINE ' || v_ver;
    RETURN NEXT;

    -- data format of the delivery (loine_delivery.data_format, missing = 1) must be readable by the functions
    -- (_data_formats(), functions before LOINE 3.0.2 read format 1)
    check_name := 'data format';
    v_n := 1;
    IF v_deliv AND EXISTS (SELECT 1 FROM pg_attribute
                           WHERE attrelid = TO_REGCLASS(FORMAT('%I.loine_delivery', p_schema))
                             AND attname = 'data_format' AND NOT attisdropped) THEN
        EXECUTE FORMAT('SELECT COALESCE(MAX(data_format), 1) FROM %I.loine_delivery', p_schema) INTO v_n;
    END IF;
    v_txt := '{1}';
    IF TO_REGPROCEDURE(FORMAT('%I._data_formats()', p_schema)) IS NOT NULL THEN
        EXECUTE FORMAT('SELECT %I._data_formats()::TEXT', p_schema) INTO v_txt;
    END IF;
    IF v_n = ANY (v_txt::INTEGER[]) THEN
        status := 'ok'; detail := 'format ' || v_n;
    ELSE
        status := 'error';
        detail := FORMAT('format %s of the delivery is not supported by LOINE %s (formats %s)', v_n, v_ver, v_txt);
    END IF;
    RETURN NEXT;

    -- projection read by the functions
    check_name := 'projection';
    EXECUTE FORMAT('SELECT %I._srid(), (SELECT MIN(srid) FROM %I.loine_installed)', p_schema, p_schema) INTO v_srid, v_inst;
    IF v_srid = v_inst THEN
        status := 'ok'; detail := 'SRID ' || v_srid;
    ELSE
        status := 'error'; detail := FORMAT('the functions use SRID %s, the countries have %s', v_srid, v_inst);
    END IF;
    RETURN NEXT;

    -- row counts
    FOREACH v_txt IN ARRAY ARRAY ['edges', 'grids']
        LOOP
            check_name := v_txt;
            EXECUTE FORMAT('SELECT count(*) FROM %I.%I', p_schema, v_txt) INTO v_n;
            IF v_deliv THEN
                EXECUTE FORMAT('SELECT %I FROM %I.loine_delivery', v_txt, p_schema) INTO v_exp;
            ELSE
                EXECUTE FORMAT('SELECT SUM(%I) FROM %I.loine_installed', v_txt, p_schema) INTO v_exp;
            END IF;
            IF v_n = v_exp THEN
                status := 'ok'; detail := v_n || ' rows';
            ELSIF v_n = 0 OR NOT v_deliv THEN
                status := CASE WHEN v_n = 0 THEN 'error' ELSE 'warning' END;
                detail := FORMAT('%s rows, expected %s', v_n, v_exp);
            ELSE
                status := 'error'; detail := FORMAT('%s rows, the delivery has %s', v_n, v_exp);
            END IF;
            RETURN NEXT;
        END LOOP;

    -- indexes
    check_name := 'indexes';
    SELECT count(*), count(*) FILTER (WHERE NOT i.indisvalid)
    INTO v_n, v_exp
    FROM pg_index i
             JOIN pg_class c ON c.oid = i.indexrelid
    WHERE c.relnamespace = p_schema::REGNAMESPACE;
    IF v_n = 0 THEN
        status := 'error'; detail := 'no indexes';
    ELSIF v_exp > 0 THEN
        status := 'error'; detail := FORMAT('%s of %s indexes are invalid', v_exp, v_n);
    ELSE
        status := 'ok'; detail := v_n || ' indexes';
    END IF;
    RETURN NEXT;

    -- base network
    check_name := 'base network';
    v_txt := loine_admin._try(FORMAT('SELECT global_n FROM %I.net_level LIMIT 1', p_schema));
    IF v_txt IS NULL THEN
        status := 'warning'; detail := 'net_level is empty';
    ELSE
        status := 'ok'; detail := v_txt || ' edges';
    END IF;
    RETURN NEXT;

    -- test route between two road segments inside the tile with the most clusters (both points at least 12 km
    -- inside the tile, so that the search area around them stays within the delivered tiles)
    check_name := 'test route';
    BEGIN
        EXECUTE FORMAT('SELECT partition_id FROM %I.cluster GROUP BY partition_id ORDER BY count(*) DESC, partition_id LIMIT 1',
                       p_schema) INTO v_tile;
        -- the clusters are stored in 4326: after the transformation tiny gaps remain between the cells, which the
        -- inner buffer would widen; closing them with +1 m first keeps the full tile area
        EXECUTE FORMAT('SELECT ST_Transform(ST_Buffer(ST_Buffer(ST_Transform(ST_Union(geom), %s), 1), -12001), 4326)
                        FROM %I.cluster WHERE partition_id = $1', v_srid, p_schema) INTO v_area USING v_tile;
        EXECUTE FORMAT('SELECT ST_X(p) AS x, ST_Y(p) AS y, m
                        FROM (SELECT ST_Transform(ST_LineInterpolatePoint(geom, 0.5), 4326) AS p,
                                     ST_LineInterpolatePoint(geom, 0.5) AS m
                              FROM %I.edges
                              WHERE partition_id = $1 AND street_cat BETWEEN 3 AND 6 AND id >= 1000000000
                              ORDER BY id) s
                        WHERE ST_Within(p, $2) LIMIT 1', p_schema) INTO a USING v_tile, v_area;
        EXECUTE FORMAT('SELECT ST_X(p) AS x, ST_Y(p) AS y
                        FROM (SELECT ST_Transform(ST_LineInterpolatePoint(geom, 0.5), 4326) AS p
                              FROM %I.edges
                              WHERE partition_id = $1 AND street_cat BETWEEN 3 AND 6 AND id >= 1000000000
                                AND ST_DWithin(geom, $3, 10000) AND NOT ST_DWithin(geom, $3, 3000)
                              ORDER BY id) s
                        WHERE ST_Within(p, $2) LIMIT 1', p_schema) INTO b USING v_tile, v_area, a.m;
        IF a.x IS NULL OR b.x IS NULL THEN
            status := 'warning'; detail := FORMAT('no road segments for a test route found in tile %s', v_tile);
        ELSE
            EXECUTE FORMAT('SELECT route_distance, route_time FROM %I.cgo_path($1, $2, $3, $4, ''car'', ''time'')', p_schema)
                INTO v_route USING a.x, a.y, b.x, b.y;
            IF v_route.route_distance IS NULL OR v_route.route_distance = 0 THEN
                status := 'warning';
                detail := FORMAT('no route found in tile %s (%s, %s → %s, %s)', v_tile,
                                 ROUND(a.x::NUMERIC, 5), ROUND(a.y::NUMERIC, 5), ROUND(b.x::NUMERIC, 5), ROUND(b.y::NUMERIC, 5));
            ELSE
                status := 'ok';
                detail := FORMAT('%s m, %s min in tile %s', v_route.route_distance, v_route.route_time, v_tile);
            END IF;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            status := 'warning'; detail := 'cgo_path: ' || SQLERRM;
    END;
    RETURN NEXT;
END;
$$;

--======================================================================================================================
-- Rewrite the schema name in the bodies of all functions and procedures of a schema (\m<from>\. → <to>.)
--======================================================================================================================
CREATE OR REPLACE FUNCTION loine_admin._rewrite_functions(p_schema TEXT, p_from TEXT, p_to TEXT)
    RETURNS INTEGER
    LANGUAGE plpgsql
AS
$$
DECLARE
    r     RECORD;
    v_def TEXT;
    v_new TEXT;
    v_n   INTEGER := 0;
BEGIN
    FOR r IN
        SELECT p.oid
        FROM pg_proc p
        WHERE p.pronamespace = p_schema::REGNAMESPACE
          AND p.prokind IN ('f', 'p')
        ORDER BY p.oid
        LOOP
            v_def := PG_GET_FUNCTIONDEF(r.oid);
            v_new := REGEXP_REPLACE(v_def, '\m' || p_from || '\.', p_to || '.', 'g');
            IF v_new <> v_def THEN
                EXECUTE v_new;
                v_n := v_n + 1;
            END IF;
        END LOOP;
    RETURN v_n;
END;
$$;

-- Privileges of an old installation on a new one: schema, tables, functions and default privileges
CREATE OR REPLACE FUNCTION loine_admin._copy_privileges(p_from TEXT, p_to TEXT)
    RETURNS VOID
    LANGUAGE plpgsql
AS
$$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT DISTINCT a.privilege_type,
                        CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE QUOTE_IDENT(PG_GET_USERBYID(a.grantee)) END AS grantee
        FROM pg_namespace n, ACLEXPLODE(n.nspacl) a
        WHERE n.nspname = p_from
          AND a.grantee <> n.nspowner
        LOOP
            EXECUTE FORMAT('GRANT %s ON SCHEMA %I TO %s', r.privilege_type, p_to, r.grantee);
        END LOOP;

    FOR r IN
        SELECT DISTINCT a.privilege_type,
                        CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE QUOTE_IDENT(PG_GET_USERBYID(a.grantee)) END AS grantee
        FROM pg_class c, ACLEXPLODE(c.relacl) a
        WHERE c.relnamespace = p_from::REGNAMESPACE
          AND c.relkind IN ('r', 'p', 'v', 'm')
          AND a.grantee <> c.relowner
        LOOP
            EXECUTE FORMAT('GRANT %s ON ALL TABLES IN SCHEMA %I TO %s', r.privilege_type, p_to, r.grantee);
        END LOOP;

    FOR r IN
        SELECT DISTINCT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE QUOTE_IDENT(PG_GET_USERBYID(a.grantee)) END AS grantee
        FROM pg_proc p, ACLEXPLODE(p.proacl) a
        WHERE p.pronamespace = p_from::REGNAMESPACE
          AND a.grantee <> p.proowner
          AND a.privilege_type = 'EXECUTE'
        LOOP
            EXECUTE FORMAT('GRANT EXECUTE ON ALL ROUTINES IN SCHEMA %I TO %s', p_to, r.grantee);
        END LOOP;

    FOR r IN
        SELECT PG_GET_USERBYID(d.defaclrole) AS owner,
               CASE d.defaclobjtype WHEN 'r' THEN 'TABLES' WHEN 'S' THEN 'SEQUENCES' WHEN 'f' THEN 'FUNCTIONS'
                                    WHEN 'T' THEN 'TYPES' END AS objtype,
               a.privilege_type,
               CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE QUOTE_IDENT(PG_GET_USERBYID(a.grantee)) END AS grantee
        FROM pg_default_acl d, ACLEXPLODE(d.defaclacl) a
        WHERE d.defaclnamespace = p_from::REGNAMESPACE
          AND d.defaclobjtype IN ('r', 'S', 'f', 'T')
        LOOP
            EXECUTE FORMAT('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I GRANT %s ON %s TO %s',
                           r.owner, p_to, r.privilege_type, r.objtype, r.grantee);
        END LOOP;
END;
$$;

-- Free name pgr_<date>[_n] for an installation that is kept
CREATE OR REPLACE FUNCTION loine_admin._free_name(p_date DATE)
    RETURNS TEXT
    LANGUAGE plpgsql
    STABLE
AS
$$
DECLARE
    v_base TEXT := 'pgr_' || TO_CHAR(COALESCE(p_date, CURRENT_DATE), 'YYYYMMDD');
    v_name TEXT := v_base;
    v_n    INTEGER := 1;
BEGIN
    WHILE TO_REGNAMESPACE(v_name) IS NOT NULL
        LOOP
            v_n := v_n + 1;
            v_name := v_base || '_' || v_n;
        END LOOP;
    RETURN v_name;
END;
$$;

--======================================================================================================================
-- Switch an installation pgr_YYYYMMDD[_n] to pgr. The previous pgr is kept under its date name (p_old => 'keep')
-- or dropped (p_old => 'drop', only if no objects outside the LOINE installations depend on it).
-- One transaction: either everything or nothing. Switching back is the same call with the old name.
--======================================================================================================================
CREATE OR REPLACE PROCEDURE loine_admin.switch_installation(
    p_schema TEXT,
    p_old    TEXT DEFAULT 'keep'
)
    LANGUAGE plpgsql
AS
$$
DECLARE
    v_old      TEXT;
    v_date     DATE;
    v_dep      TEXT;
    v_n_old    INTEGER := 0;
    v_n_new    INTEGER;
    v_had_old  BOOLEAN;
    i          RECORD;
    n          RECORD;
BEGIN
    IF p_schema IS NULL OR p_schema !~ '^pgr_[0-9]{8}(_[0-9]+)?$' THEN
        RAISE EXCEPTION 'Loine: % is not the name of a delivery (pgr_YYYYMMDD or pgr_YYYYMMDD_n)', p_schema;
    END IF;
    IF p_old NOT IN ('keep', 'drop') THEN
        RAISE EXCEPTION 'Loine: p_old must be keep or drop, not %', p_old;
    END IF;
    IF TO_REGNAMESPACE(p_schema) IS NULL THEN
        RAISE EXCEPTION 'Loine: schema % does not exist', p_schema;
    END IF;
    SELECT * INTO n FROM loine_admin.installations() x WHERE x.schema_name = p_schema;
    IF NOT FOUND OR n.countries IS NULL THEN
        RAISE EXCEPTION 'Loine: % is not a LOINE installation (table loine_installed missing or empty)', p_schema;
    END IF;
    IF NOT n.functions THEN
        RAISE EXCEPTION 'Loine: the functions are not installed in %', p_schema
            USING HINT = 'Install loine_functions.sql with "pgr." replaced by "' || p_schema || '." first.';
    END IF;

    -- previous installation
    SELECT * INTO i FROM loine_admin.installations() x WHERE x.schema_name = 'pgr';
    v_had_old := FOUND;
    -- a schema pgr without LOINE installation: drop it if it is empty, otherwise stop
    IF NOT v_had_old AND TO_REGNAMESPACE('pgr') IS NOT NULL THEN
        IF EXISTS (SELECT 1 FROM pg_class WHERE relnamespace = 'pgr'::REGNAMESPACE)
            OR EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'pgr'::REGNAMESPACE)
            OR EXISTS (SELECT 1 FROM pg_type WHERE typnamespace = 'pgr'::REGNAMESPACE) THEN
            RAISE EXCEPTION 'Loine: schema pgr exists but is no LOINE installation (no table loine_installed)'
                USING HINT = 'Rename or drop it first.';
        END IF;
        DROP SCHEMA pgr;
    END IF;
    IF v_had_old THEN
        IF i.source IS DISTINCT FROM n.source OR i.srid IS DISTINCT FROM n.srid THEN
            RAISE NOTICE 'Loine: the new installation has another data source or region (% %, before % %)',
                n.source, n.region, i.source, i.region;
        END IF;
        IF p_old = 'drop' THEN
            SELECT STRING_AGG(d.object || ' → ' || d.depends_on, '; ') INTO v_dep FROM loine_admin.dependents('pgr') d;
            IF v_dep IS NOT NULL THEN
                RAISE EXCEPTION 'Loine: the previous installation pgr cannot be dropped, other objects depend on it: %', v_dep
                    USING HINT = 'Keep it (p_old => ''keep'') or remove the dependent objects first.';
            END IF;
            DROP SCHEMA pgr CASCADE;
            INSERT INTO loine_admin.installation_history (schema_name, action, delivery_date, loine_version, countries, note)
            VALUES ('pgr', 'dropped', i.delivery_date, i.loine_version, STRING_TO_ARRAY(i.countries, ', '),
                    'dropped when switching to ' || p_schema);
        ELSE
            v_old := loine_admin._free_name(i.delivery_date);
            EXECUTE FORMAT('ALTER SCHEMA pgr RENAME TO %I', v_old);
            v_n_old := loine_admin._rewrite_functions(v_old, 'pgr', v_old);
            INSERT INTO loine_admin.installation_history (schema_name, action, delivery_date, loine_version, countries, note)
            VALUES (v_old, 'kept_as', i.delivery_date, i.loine_version, STRING_TO_ARRAY(i.countries, ', '),
                    'previous pgr, kept when switching to ' || p_schema);
        END IF;
    END IF;

    -- new installation
    EXECUTE FORMAT('ALTER SCHEMA %I RENAME TO pgr', p_schema);
    v_n_new := loine_admin._rewrite_functions('pgr', p_schema, 'pgr');
    IF v_old IS NOT NULL THEN
        PERFORM loine_admin._copy_privileges(v_old, 'pgr');
    END IF;
    INSERT INTO loine_admin.installation_history (schema_name, action, delivery_date, loine_version, countries, note)
    VALUES ('pgr', 'activated', n.delivery_date, n.loine_version, STRING_TO_ARRAY(n.countries, ', '),
            'was ' || p_schema);

    RAISE NOTICE 'Loine: % is now pgr (LOINE %, %; % functions adjusted)%', p_schema, n.loine_version, n.countries, v_n_new,
        CASE WHEN v_old IS NOT NULL THEN FORMAT('; previous installation kept as %s (%s functions adjusted)', v_old, v_n_old)
             WHEN v_had_old THEN '; previous installation dropped' ELSE '' END;
    RAISE NOTICE 'Loine: sessions that used LOINE should reconnect (SELECT loine_admin.terminate_sessions(); disconnects all other sessions of this database)';
END;
$$;

--======================================================================================================================
-- Drop an installation that is not active
--======================================================================================================================
CREATE OR REPLACE PROCEDURE loine_admin.drop_installation(p_schema TEXT)
    LANGUAGE plpgsql
AS
$$
DECLARE
    i     RECORD;
    v_dep TEXT;
BEGIN
    IF p_schema IS NULL OR p_schema !~ '^pgr_[0-9]{8}(_[0-9]+)?$' THEN
        RAISE EXCEPTION 'Loine: % is not the name of an inactive installation (pgr_YYYYMMDD or pgr_YYYYMMDD_n)', p_schema
            USING HINT = 'The active installation pgr cannot be dropped here.';
    END IF;
    IF TO_REGNAMESPACE(p_schema) IS NULL THEN
        RAISE EXCEPTION 'Loine: schema % does not exist', p_schema;
    END IF;
    SELECT STRING_AGG(d.object || ' → ' || d.depends_on, '; ') INTO v_dep FROM loine_admin.dependents(p_schema) d;
    IF v_dep IS NOT NULL THEN
        RAISE EXCEPTION 'Loine: % cannot be dropped, other objects depend on it: %', p_schema, v_dep;
    END IF;
    SELECT * INTO i FROM loine_admin.installations() x WHERE x.schema_name = p_schema;
    EXECUTE FORMAT('DROP SCHEMA %I CASCADE', p_schema);
    INSERT INTO loine_admin.installation_history (schema_name, action, delivery_date, loine_version, countries)
    VALUES (p_schema, 'dropped', i.delivery_date, i.loine_version, STRING_TO_ARRAY(i.countries, ', '));
    RAISE NOTICE 'Loine: % dropped', p_schema;
END;
$$;

--======================================================================================================================
-- Disconnect all other client sessions of this database (after switching); returns the number of sessions
--======================================================================================================================
CREATE OR REPLACE FUNCTION loine_admin.terminate_sessions()
    RETURNS INTEGER
    LANGUAGE sql
    VOLATILE
AS
$$
SELECT count(*)::INTEGER
FROM pg_stat_activity a
WHERE a.datname = CURRENT_DATABASE()
  AND a.pid <> PG_BACKEND_PID()
  AND a.backend_type = 'client backend'
  AND PG_TERMINATE_BACKEND(a.pid);
$$;
