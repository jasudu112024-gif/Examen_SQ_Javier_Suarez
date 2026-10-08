/*
Proyecto: Gestión de Coworking y Oficinas Compartidas
Módulo: Integración de reservas de plataformas externas (Airbnb, Meetup, etc.)
Archivo: 1892-examen.sql
*/
USE coworking_db;

-- =====================================================================
-- 1. TABLA: ReservasExternas
-- Cada fila es una reserva recibida desde una plataforma externa. El
-- procedimiento la lee, la valida y deja aquí el resultado de la importación.
-- =====================================================================
CREATE TABLE IF NOT EXISTS ReservasExternas (
    -- Identificador interno de la reserva externa (parámetro del procedimiento)
    id INT AUTO_INCREMENT PRIMARY KEY,

    -- Plataforma de origen (Airbnb, Meetup, ...)
    plataforma VARCHAR(50) NOT NULL,

    -- Código de la reserva en la plataforma; evita importar dos veces la misma.
    -- Es opcional: los valores NULL no cuentan para el UNIQUE.
    codigo_externo VARCHAR(60) NULL,

    -- Fecha y hora de INICIO de la reserva
    fecha_reserva DATETIME NOT NULL,

    -- Espacio solicitado (debe existir en la tabla espacios)
    espacio_id INT NOT NULL,

    -- Identificador del cliente en la plataforma. Se usa como email si contiene
    -- "@"; si no, el procedimiento genera un email sintético a partir de él.
    usuario_externo VARCHAR(100) NOT NULL,

    -- Nombre visible del cliente (opcional, solo para crear el usuario temporal)
    nombre_usuario_externo VARCHAR(100) NULL,

    -- Duración de la reserva en minutos (la fecha fin se calcula sumándola)
    duracion_minutos INT NOT NULL,

    -- Resultado de la importación: Pendiente (sin procesar), Importada o Rechazada
    estado_importacion ENUM('Pendiente', 'Importada', 'Rechazada') NOT NULL DEFAULT 'Pendiente',

    -- Reserva interna generada (NULL mientras no se importe)
    id_reserva_interna INT NULL,

    -- Motivo cuando la reserva fue rechazada (conflicto, horario, espacio, ...)
    motivo_rechazo VARCHAR(255) NULL,

    -- Cuándo se procesó la reserva
    fecha_importacion DATETIME NULL,

    -- Cuándo llegó la reserva a nuestro sistema
    fecha_recepcion DATETIME DEFAULT CURRENT_TIMESTAMP,

    -- La duración debe ser positiva
    CONSTRAINT chk_resext_duracion CHECK (duracion_minutos > 0),

    -- No se puede registrar dos veces el mismo código de una misma plataforma
    CONSTRAINT uq_resext_codigo UNIQUE (plataforma, codigo_externo),

    -- El espacio debe existir
    CONSTRAINT fk_resext_espacio FOREIGN KEY (espacio_id)
        REFERENCES espacios(id_espacio),

    -- Si se borra la reserva interna, solo se pierde el vínculo (no la fila externa)
    CONSTRAINT fk_resext_reserva FOREIGN KEY (id_reserva_interna)
        REFERENCES reservas(id_reserva) ON DELETE SET NULL,

    -- Índice para localizar rápido las reservas pendientes de procesar
    INDEX idx_resext_estado (estado_importacion, fecha_reserva)
);

-- =====================================================================
-- 2. PROCEDIMIENTO: sp_importar_reserva_externa
-- Parámetros:
--   p_id_reserva_externa (IN)  id de la fila de ReservasExternas a importar
--   p_id_reserva         (OUT) id de la reserva interna creada (NULL si no se creó)
--   p_resultado          (OUT) 'OK ...', 'RECHAZADA: <motivo>' o 'IGNORADA: ...'
-- Un error inesperado de MySQL revierte la transacción y se propaga al llamador.
-- =====================================================================
DROP PROCEDURE IF EXISTS sp_importar_reserva_externa;

DELIMITER //

CREATE PROCEDURE sp_importar_reserva_externa(
    IN  p_id_reserva_externa INT,
    OUT p_id_reserva         INT,
    OUT p_resultado          VARCHAR(255)
)
proc: BEGIN
    -- ---------- Variables con los datos de la reserva externa ----------
    DECLARE v_existe          INT DEFAULT 0;      -- 1 si la fila externa existe
    DECLARE v_plataforma      VARCHAR(50);
    DECLARE v_inicio          DATETIME;           -- inicio de la reserva
    DECLARE v_fin             DATETIME;           -- fin = inicio + duración
    DECLARE v_id_espacio      INT;
    DECLARE v_usuario_ext     VARCHAR(100);
    DECLARE v_nombre_ext      VARCHAR(100);
    DECLARE v_duracion        INT;
    DECLARE v_estado_imp      VARCHAR(20);        -- estado actual de la importación
    DECLARE v_id_reserva_prev INT;                -- reserva interna previa (si ya se importó)

    -- ---------- Variables con los datos del espacio ----------
    DECLARE v_estado_espacio  VARCHAR(20);
    DECLARE v_capacidad       INT;
    DECLARE v_apertura        TIME;
    DECLARE v_cierre          TIME;
    DECLARE v_tipo_espacio    VARCHAR(50);

    -- ---------- Variables de validación y usuario ----------
    DECLARE v_solapadas       INT DEFAULT 0;      -- reservas que se cruzan con la nueva
    DECLARE v_motivo          VARCHAR(255) DEFAULT NULL; -- motivo de rechazo (NULL = válida)
    DECLARE v_email           VARCHAR(100);
    DECLARE v_id_usuario      INT;
    DECLARE v_usuario_creado  TINYINT DEFAULT 0;  -- 1 si se creó un usuario temporal
    DECLARE v_id_nueva        INT;                -- id de la reserva interna creada
    DECLARE v_msg             VARCHAR(255);       -- mensaje de error capturado en el handler

    -- Error de regla de negocio lanzado con SIGNAL SQLSTATE '45000' (por ejemplo,
    -- el trigger que impide reservas solapadas). No se aborta la ejecución:
    -- se deshace la transacción, se registra el rechazo y se informa en p_resultado.
    DECLARE EXIT HANDLER FOR SQLSTATE '45000'
    BEGIN
        -- Captura el texto del error lanzado por el trigger
        GET DIAGNOSTICS CONDITION 1 v_msg = MESSAGE_TEXT;
        ROLLBACK;

        -- Tras el ROLLBACK se registra el rechazo en una transacción nueva
        UPDATE ReservasExternas
           SET estado_importacion = 'Rechazada',
               motivo_rechazo     = LEFT(CONCAT('Regla de la base de datos: ', v_msg), 255),
               fecha_importacion  = NOW()
         WHERE id = p_id_reserva_externa;
        COMMIT;

        SET p_id_reserva = NULL;
        SET p_resultado  = CONCAT('RECHAZADA: ', v_msg);
    END;

    -- Ante cualquier otro error SQL inesperado: deshace todo y propaga el error
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    -- Valores iniciales de los parámetros de salida
    SET p_id_reserva = NULL;
    SET p_resultado  = NULL;

    START TRANSACTION;

    -- ---------------------------------------------------------------
    -- PASO 1: Cargar la reserva externa y bloquear su fila
    -- ---------------------------------------------------------------
    -- Comprobamos primero que exista para dar un mensaje claro
    SELECT COUNT(*) INTO v_existe
      FROM ReservasExternas
     WHERE id = p_id_reserva_externa;

    IF v_existe = 0 THEN
        ROLLBACK;
        SET p_resultado = CONCAT('RECHAZADA: no existe la reserva externa #', p_id_reserva_externa);
        LEAVE proc;
    END IF;

    -- FOR UPDATE evita que dos sesiones importen la misma fila a la vez
    SELECT plataforma, fecha_reserva, espacio_id, usuario_externo,
           nombre_usuario_externo, duracion_minutos, estado_importacion,
           id_reserva_interna
      INTO v_plataforma, v_inicio, v_id_espacio, v_usuario_ext,
           v_nombre_ext, v_duracion, v_estado_imp, v_id_reserva_prev
      FROM ReservasExternas
     WHERE id = p_id_reserva_externa
       FOR UPDATE;

    -- Idempotencia: una reserva ya importada no se vuelve a crear
    IF v_estado_imp = 'Importada' THEN
        ROLLBACK;
        SET p_id_reserva = v_id_reserva_prev;
        SET p_resultado  = CONCAT('IGNORADA: la reserva externa ya fue importada como reserva #', v_id_reserva_prev);
        LEAVE proc;
    END IF;

    -- Fecha de fin de la reserva interna
    SET v_fin = v_inicio + INTERVAL v_duracion MINUTE;

    -- ---------------------------------------------------------------
    -- PASO 2: Cargar el espacio y bloquearlo
    -- ---------------------------------------------------------------
    -- FOR UPDATE OF e bloquea solo la fila del espacio. Así, dos importaciones
    -- simultáneas del MISMO espacio se ejecutan una tras otra y no pueden
    -- colarse reservas solapadas; espacios distintos siguen en paralelo.
    SELECT e.estado, e.capacidad_maxima, e.hora_apertura, e.hora_cierre, te.nombre
      INTO v_estado_espacio, v_capacidad, v_apertura, v_cierre, v_tipo_espacio
      FROM espacios e
      INNER JOIN tipos_espacio te ON te.id_tipo_espacio = e.id_tipo_espacio
     WHERE e.id_espacio = v_id_espacio
       FOR UPDATE OF e;

    -- ---------------------------------------------------------------
    -- PASO 3: Validaciones (se guarda el PRIMER motivo que falle)
    -- ---------------------------------------------------------------

    -- 3.1 El espacio debe estar disponible (no en mantenimiento ni inactivo)
    IF v_motivo IS NULL AND v_estado_espacio <> 'Disponible' THEN
        SET v_motivo = CONCAT('El espacio no está disponible (estado: ', v_estado_espacio, ')');
    END IF;

    -- 3.2 La reserva debe empezar y terminar el mismo día
    IF v_motivo IS NULL AND DATE(v_inicio) <> DATE(v_fin) THEN
        SET v_motivo = 'La reserva cruza la medianoche; debe empezar y terminar el mismo día';
    END IF;

    -- 3.3 La reserva debe estar dentro del horario de apertura del espacio
    IF v_motivo IS NULL AND (TIME(v_inicio) < v_apertura OR TIME(v_fin) > v_cierre) THEN
        SET v_motivo = CONCAT('Fuera del horario del espacio (', v_apertura, ' - ', v_cierre, ')');
    END IF;

    -- 3.4 Conflicto de horario con reservas existentes del mismo espacio.
    --     Dos intervalos se solapan si cada uno empieza antes de que termine el
    --     otro. Con "<" y ">" estrictos, una reserva que empieza justo cuando
    --     otra termina NO es conflicto.
    --     Solo cuentan reservas vigentes (Pendiente de Confirmación o Confirmada).
    --     Todos los espacios se tratan como exclusivos (igual que el trigger).
    IF v_motivo IS NULL THEN
        SELECT COUNT(*) INTO v_solapadas
          FROM reservas r
         WHERE r.id_espacio   = v_id_espacio
           AND r.estado IN ('Pendiente de Confirmación', 'Confirmada')
           AND r.fecha_inicio < v_fin
           AND r.fecha_fin    > v_inicio;

        IF v_solapadas > 0 THEN
            -- Cualquier cruce con una reserva vigente es conflicto
            SET v_motivo = CONCAT('Conflicto de horario con ', v_solapadas,
                                  ' reserva(s) existente(s) en el espacio');
        END IF;
    END IF;

    -- ---------------------------------------------------------------
    -- PASO 4: Si alguna validación falló, registrar el rechazo y terminar
    -- ---------------------------------------------------------------
    IF v_motivo IS NOT NULL THEN
        UPDATE ReservasExternas
           SET estado_importacion = 'Rechazada',
               motivo_rechazo     = v_motivo,
               fecha_importacion  = NOW()
         WHERE id = p_id_reserva_externa;

        COMMIT;  -- el rechazo queda guardado para consulta posterior
        SET p_resultado = CONCAT('RECHAZADA: ', v_motivo);
        LEAVE proc;
    END IF;

    -- ---------------------------------------------------------------
    -- PASO 5: Buscar el usuario; si no existe, crear uno temporal
    -- ---------------------------------------------------------------
    -- Email del cliente: se usa tal cual si ya es un email; si no, se genera
    -- uno sintético con dominio ".local" a partir del identificador externo.
    SET v_email = IF(LOCATE('@', v_usuario_ext) > 0,
                     LEFT(TRIM(v_usuario_ext), 100),
                     CONCAT(LEFT(REPLACE(LOWER(TRIM(v_usuario_ext)), ' ', '.'), 60), '@externo.local'));

    -- MIN() devuelve NULL (sin error) cuando no hay coincidencias
    SELECT MIN(id_usuario) INTO v_id_usuario
      FROM usuarios
     WHERE email = v_email;

    IF v_id_usuario IS NULL THEN
        -- identificacion: prefijo EXT- + id externo (único por reserva externa).
        -- fecha_nacimiento es obligatoria en usuarios: se usa un valor
        -- centinela (1900-01-01) que marca al usuario como temporal.
        INSERT INTO usuarios (id_empresa, identificacion, nombre, apellidos, fecha_nacimiento, email, telefono)
        VALUES (NULL,
                CONCAT('EXT-', LPAD(p_id_reserva_externa, 10, '0')),
                LEFT(COALESCE(NULLIF(TRIM(v_nombre_ext), ''), SUBSTRING_INDEX(v_email, '@', 1)), 50),
                LEFT(CONCAT('Externo (', v_plataforma, ')'), 50),
                '1900-01-01',
                v_email,
                NULL);

        SET v_id_usuario     = LAST_INSERT_ID();
        SET v_usuario_creado = 1;
    END IF;

    -- ---------------------------------------------------------------
    -- PASO 6: Crear la reserva interna
    -- ---------------------------------------------------------------
    -- Estado 'Confirmada': la plataforma ya la aceptó. Con 'Pendiente de
    -- Confirmación', evt_cancelar_reservas_no_confirmadas la cancelaría a las 2 h.
    INSERT INTO reservas (id_usuario, id_espacio, fecha_inicio, fecha_fin, estado, asistio)
    VALUES (v_id_usuario, v_id_espacio, v_inicio, v_fin, 'Confirmada', FALSE);

    SET v_id_nueva = LAST_INSERT_ID();

    -- ---------------------------------------------------------------
    -- PASO 7: Marcar la reserva externa como importada y cerrar
    -- ---------------------------------------------------------------
    UPDATE ReservasExternas
       SET estado_importacion = 'Importada',
           id_reserva_interna = v_id_nueva,
           motivo_rechazo     = NULL,
           fecha_importacion  = NOW()
     WHERE id = p_id_reserva_externa;

    COMMIT;

    SET p_id_reserva = v_id_nueva;
    SET p_resultado  = CONCAT('OK: reserva interna #', v_id_nueva, ' creada',
                              IF(v_usuario_creado = 1,
                                 CONCAT(' (usuario temporal #', v_id_usuario, ' creado)'),
                                 CONCAT(' (usuario existente #', v_id_usuario, ')')));
END//

DELIMITER ;

-- =====================================================================
-- 3. DATOS DE EJEMPLO PARA PROBAR
-- Todas las fechas son de noviembre de 2026 para no chocar con los datos
-- iniciales. La sección es re-ejecutable: empieza borrando los datos de
-- prueba de una corrida anterior (paso 3.0).
-- =====================================================================

-- 3.0 Limpieza previa de datos de prueba (solo toca datos creados por este script).
--     Es necesaria porque el trigger de reservas rechaza (error 1644) cualquier
--     reserva que se cruce con otra del mismo espacio, así que insertar de nuevo
--     las reservas base fallaría si quedaron de una corrida anterior.

-- MySQL Workbench activa por defecto el "safe update mode" (error 1175), que
-- prohíbe DELETE/UPDATE cuyo WHERE no use una columna clave. Lo desactivamos solo
-- para esta sesión y guardamos el valor anterior para restaurarlo al terminar.
SET @safe_updates_prev = @@SQL_SAFE_UPDATES;
SET SQL_SAFE_UPDATES = 0;

-- Borra las reservas internas creadas por el procedimiento a partir de filas TEST-%
-- y las dos reservas base exactas del paso 3.1.
DELETE FROM reservas
 WHERE id_reserva IN (SELECT id_reserva_interna
                        FROM ReservasExternas
                       WHERE codigo_externo LIKE 'TEST-%'
                         AND id_reserva_interna IS NOT NULL)
    OR (id_usuario = 1 AND id_espacio = 7 AND fecha_inicio = '2026-11-10 10:00:00')
    OR (id_usuario = 1 AND id_espacio = 3 AND fecha_inicio = '2026-11-13 09:00:00');

-- Borra las filas externas de prueba
DELETE FROM ReservasExternas WHERE codigo_externo LIKE 'TEST-%';

-- Borra los usuarios temporales creados por las pruebas
DELETE FROM usuarios WHERE identificacion LIKE 'EXT-%';

-- Restaura el safe update mode a su valor original
SET SQL_SAFE_UPDATES = @safe_updates_prev;

-- 3.1 Reservas internas "base" contra las que se probarán los conflictos
--     (usuario 1 = Carlos Méndez)
--     - Sala Reuniones Andes (7): 10-nov 10:00 a 12:00
--     - Escritorio Flex Silencioso (3): 13-nov 09:00 a 13:00
INSERT INTO reservas (id_usuario, id_espacio, fecha_inicio, fecha_fin, estado) VALUES
(1, 7, '2026-11-10 10:00:00', '2026-11-10 12:00:00', 'Confirmada'),
(1, 3, '2026-11-13 09:00:00', '2026-11-13 13:00:00', 'Confirmada');

-- 3.2 Reservas externas de prueba (una por escenario). Se guarda cada id en
--     una variable de sesión (@t1, @t2, ...) para llamarlas después.

-- T1: Airbnb, Sala Caribe (8), 10-nov 09:00, 120 min -> sin conflicto, usuario nuevo
INSERT INTO ReservasExternas (plataforma, codigo_externo, fecha_reserva, espacio_id, usuario_externo, nombre_usuario_externo, duracion_minutos)
VALUES ('Airbnb', 'TEST-ABNB-001', '2026-11-10 09:00:00', 8, 'ana.turista@example.com', 'Ana Turista', 120);
SET @t1 = LAST_INSERT_ID();

-- T2: Meetup, Sala Andes (7), 10-nov 11:00, 60 min -> CONFLICTO con la reserva base (10:00-12:00)
INSERT INTO ReservasExternas (plataforma, codigo_externo, fecha_reserva, espacio_id, usuario_externo, nombre_usuario_externo, duracion_minutos)
VALUES ('Meetup', 'TEST-MEET-001', '2026-11-10 11:00:00', 7, 'organizador.meetup@example.com', 'Organizador Meetup', 60);
SET @t2 = LAST_INSERT_ID();

-- T3: Meetup, Sala Andes (7), 10-nov 12:00, 60 min -> empieza justo cuando termina la base: SIN conflicto
INSERT INTO ReservasExternas (plataforma, codigo_externo, fecha_reserva, espacio_id, usuario_externo, nombre_usuario_externo, duracion_minutos)
VALUES ('Meetup', 'TEST-MEET-002', '2026-11-10 12:00:00', 7, 'organizador.meetup@example.com', 'Organizador Meetup', 60);
SET @t3 = LAST_INSERT_ID();

-- T4: Airbnb, Sala Caribe (8), 10-nov 10:00, 60 min -> CONFLICTO con la reserva creada por T1 (09:00-11:00)
INSERT INTO ReservasExternas (plataforma, codigo_externo, fecha_reserva, espacio_id, usuario_externo, nombre_usuario_externo, duracion_minutos)
VALUES ('Airbnb', 'TEST-ABNB-002', '2026-11-10 10:00:00', 8, 'ana.turista@example.com', 'Ana Turista', 60);
SET @t4 = LAST_INSERT_ID();

-- T5: Airbnb, Sala Pacífico (9), 11-nov 09:00, 180 min -> sin conflicto, REUTILIZA el usuario de T1
INSERT INTO ReservasExternas (plataforma, codigo_externo, fecha_reserva, espacio_id, usuario_externo, nombre_usuario_externo, duracion_minutos)
VALUES ('Airbnb', 'TEST-ABNB-003', '2026-11-11 09:00:00', 9, 'ana.turista@example.com', 'Ana Turista', 180);
SET @t5 = LAST_INSERT_ID();

-- T6: Airbnb, Oficina Privada 201 (6, en Mantenimiento) -> RECHAZADA por estado del espacio
INSERT INTO ReservasExternas (plataforma, codigo_externo, fecha_reserva, espacio_id, usuario_externo, nombre_usuario_externo, duracion_minutos)
VALUES ('Airbnb', 'TEST-ABNB-004', '2026-11-11 10:00:00', 6, 'viajero.mantenimiento@example.com', 'Viajero', 60);
SET @t6 = LAST_INSERT_ID();

-- T7: Meetup, Sala Andes (7), 12-nov 21:30, 90 min -> termina 23:00 y la sala cierra a las 22:00: RECHAZADA por horario
INSERT INTO ReservasExternas (plataforma, codigo_externo, fecha_reserva, espacio_id, usuario_externo, nombre_usuario_externo, duracion_minutos)
VALUES ('Meetup', 'TEST-MEET-003', '2026-11-12 21:30:00', 7, 'organizador.meetup@example.com', 'Organizador Meetup', 90);
SET @t7 = LAST_INSERT_ID();

-- T8: Meetup, Escritorio Flex Silencioso (3), 13-nov 10:00, 120 min -> se cruza con la reserva base
--     (09:00-13:00): CONFLICTO, RECHAZADA (todos los espacios son exclusivos)
INSERT INTO ReservasExternas (plataforma, codigo_externo, fecha_reserva, espacio_id, usuario_externo, nombre_usuario_externo, duracion_minutos)
VALUES ('Meetup', 'TEST-MEET-004', '2026-11-13 10:00:00', 3, 'coworker.visitante@example.com', 'Coworker Visitante', 120);
SET @t8 = LAST_INSERT_ID();

-- T9: Airbnb, Sala Pacífico (9), 14-nov 14:00, 60 min -> el email ya pertenece a un usuario real
--     (Carlos Méndez, id 1): se reutiliza y NO se crea usuario temporal
INSERT INTO ReservasExternas (plataforma, codigo_externo, fecha_reserva, espacio_id, usuario_externo, nombre_usuario_externo, duracion_minutos)
VALUES ('Airbnb', 'TEST-ABNB-005', '2026-11-14 14:00:00', 9, 'carlos.mendez@technova.co', 'Carlos Méndez', 60);
SET @t9 = LAST_INSERT_ID();

-- =====================================================================
-- 4. EJECUCIÓN DE LAS PRUEBAS
-- Cada CALL devuelve en @rN el id de la reserva creada y en @mN el resultado.
-- =====================================================================
CALL sp_importar_reserva_externa(@t1, @r1, @m1);
CALL sp_importar_reserva_externa(@t2, @r2, @m2);
CALL sp_importar_reserva_externa(@t3, @r3, @m3);
CALL sp_importar_reserva_externa(@t4, @r4, @m4);
CALL sp_importar_reserva_externa(@t5, @r5, @m5);
CALL sp_importar_reserva_externa(@t6, @r6, @m6);
CALL sp_importar_reserva_externa(@t7, @r7, @m7);
CALL sp_importar_reserva_externa(@t8, @r8, @m8);
CALL sp_importar_reserva_externa(@t9, @r9, @m9);

-- T10: volver a importar T1 -> debe responder IGNORADA (ya importada) sin duplicar la reserva
CALL sp_importar_reserva_externa(@t1, @r10, @m10);

-- =====================================================================
-- 5. VERIFICACIÓN
-- =====================================================================

-- 5.1 Resultado de cada prueba. Esperado:
--     T1 OK (usuario nuevo) | T2 RECHAZADA (conflicto) | T3 OK (usuario nuevo)
--     T4 RECHAZADA (conflicto) | T5 OK (usuario existente) | T6 RECHAZADA (mantenimiento)
--     T7 RECHAZADA (horario) | T8 RECHAZADA (conflicto) | T9 OK (usuario existente) | T10 IGNORADA
SELECT 'T1'  AS prueba, @r1  AS id_reserva, @m1  AS resultado UNION ALL
SELECT 'T2',  @r2,  @m2  UNION ALL
SELECT 'T3',  @r3,  @m3  UNION ALL
SELECT 'T4',  @r4,  @m4  UNION ALL
SELECT 'T5',  @r5,  @m5  UNION ALL
SELECT 'T6',  @r6,  @m6  UNION ALL
SELECT 'T7',  @r7,  @m7  UNION ALL
SELECT 'T8',  @r8,  @m8  UNION ALL
SELECT 'T9',  @r9,  @m9  UNION ALL
SELECT 'T10', @r10, @m10;

-- 5.2 Estado final de las reservas externas con su reserva interna y su usuario
SELECT re.id, re.plataforma, re.codigo_externo, re.estado_importacion,
       re.motivo_rechazo, e.nombre AS espacio,
       r.fecha_inicio, r.fecha_fin,
       u.id_usuario, u.email, u.identificacion
  FROM ReservasExternas re
  INNER JOIN espacios e ON e.id_espacio = re.espacio_id
  LEFT  JOIN reservas r ON r.id_reserva = re.id_reserva_interna
  LEFT  JOIN usuarios u ON u.id_usuario = r.id_usuario
 WHERE re.codigo_externo LIKE 'TEST-%'
 ORDER BY re.id;

-- 5.3 Usuarios temporales creados (deben ser 2: ana.turista y organizador.meetup)
SELECT id_usuario, identificacion, nombre, apellidos, email
  FROM usuarios
 WHERE identificacion LIKE 'EXT-%';

-- =====================================================================
-- 6. LIMPIEZA TOTAL DE NOVIEMBRE (opcional)
-- El paso 3.0 ya limpia los datos de prueba antes de cada corrida. Esto solo
-- sirve para vaciar noviembre, borra todas las reservas del
-- 10 al 14 de noviembre de 2026, sean de prueba o no.
-- =====================================================================
-- DELETE FROM reservas WHERE fecha_inicio >= '2026-11-10' AND fecha_inicio < '2026-11-15';
-- DELETE FROM ReservasExternas WHERE codigo_externo LIKE 'TEST-%';
-- DELETE FROM usuarios WHERE identificacion LIKE 'EXT-%';
