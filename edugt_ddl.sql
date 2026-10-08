-- ============================================================
-- EDUGT — DDL completo T-SQL
-- Base de Datos II | Universidad Rafael Landívar | 2026
-- ============================================================

-- ============================================================
-- USERS AND ROLES
-- ============================================================

CREATE TABLE users (
    id            INT           IDENTITY(1,1) PRIMARY KEY,
    first_name    VARCHAR(150)  NOT NULL,
    last_name     VARCHAR(150)  NOT NULL,
    email         VARCHAR(200)  NOT NULL,
    password_hash VARCHAR(255)  NOT NULL,
    role          VARCHAR(20)   NOT NULL,
    registered_at DATETIME      NOT NULL DEFAULT GETDATE(),
    active        BIT           NOT NULL DEFAULT 1,

    CONSTRAINT UQ_users_email   UNIQUE (email),
    -- Solo roles válidos del sistema
    CONSTRAINT CK_users_role    CHECK (role IN ('student', 'instructor', 'academic', 'admin'))
);

CREATE TABLE wallets (
    id      INT            IDENTITY(1,1) PRIMARY KEY,
    user_id INT            NOT NULL,
    balance DECIMAL(12,2)  NOT NULL DEFAULT 0,
    -- version para control de concurrencia optimista
    version INT            NOT NULL DEFAULT 0,

    CONSTRAINT FK_wallets_user    FOREIGN KEY (user_id) REFERENCES users(id),
    CONSTRAINT UQ_wallets_user    UNIQUE (user_id),
    -- El saldo nunca puede ser negativo
    CONSTRAINT CK_wallets_balance CHECK (balance >= 0),
    CONSTRAINT CK_wallets_version CHECK (version >= 0)
);

CREATE TABLE wallet_movements (
    id                INT           IDENTITY(1,1) PRIMARY KEY,
    wallet_id         INT           NOT NULL,
    type              VARCHAR(30)   NOT NULL,
    concept           VARCHAR(100)  NOT NULL,
    amount            DECIMAL(12,2) NOT NULL,
    -- FKs opcionales: solo una aplica según el concept
    enrollment_id     INT           NULL,
    refund_id         INT           NULL,
    payout_id         INT           NULL,
    chargeback_id     INT           NULL,
    created_at        DATETIME      NOT NULL DEFAULT GETDATE(),
    resulting_balance DECIMAL(12,2) NOT NULL,

    CONSTRAINT FK_wm_wallet       FOREIGN KEY (wallet_id)     REFERENCES wallets(id),
    -- Las FKs a las otras tablas se agregan después de crearlas (ver abajo)
    CONSTRAINT CK_wm_type         CHECK (type    IN ('debit', 'credit')),
    CONSTRAINT CK_wm_concept      CHECK (concept IN ('enrollment', 'refund', 'payout', 'adjustment')),
    -- El monto siempre positivo; el type indica dirección
    CONSTRAINT CK_wm_amount       CHECK (amount > 0),
    CONSTRAINT CK_wm_balance      CHECK (resulting_balance >= 0)
    -- Nota: full audit trail de todas las transacciones de billetera
);

-- ============================================================
-- PLATFORM CONFIGURATION
-- ============================================================

-- Tabla singleton: parámetros globales configurables por el admin.
-- El CHECK (id = 1) garantiza que nunca exista más de una fila.
-- Solo va aquí lo que el enunciado dice explícitamente que el admin configura
-- y que puede cambiar en el tiempo; valores fijos del negocio (ej: mínimo 3 módulos)
-- se validan directamente en los SPs.
CREATE TABLE platform_config (
    id               INT           NOT NULL DEFAULT 1,
    course_price_min DECIMAL(10,2) NOT NULL DEFAULT 1.00,
    course_price_max DECIMAL(10,2) NOT NULL DEFAULT 5000.00,
    updated_at       DATETIME      NOT NULL DEFAULT GETDATE(),
    updated_by       INT           NOT NULL,

    CONSTRAINT PK_platform_config  PRIMARY KEY (id),
    CONSTRAINT FK_pc_updated_by    FOREIGN KEY (updated_by) REFERENCES users(id),
    -- Garantiza fila única; nunca puede haber un id distinto de 1
    CONSTRAINT CK_pc_single_row    CHECK (id = 1),
    CONSTRAINT CK_pc_price_min     CHECK (course_price_min > 0),
    -- El máximo siempre debe ser mayor al mínimo
    CONSTRAINT CK_pc_price_max     CHECK (course_price_max > course_price_min)
);

-- ============================================================
-- CATALOG: CATEGORIES AND COURSES
-- ============================================================

CREATE TABLE categories (
    id                  INT           IDENTITY(1,1) PRIMARY KEY,
    name                VARCHAR(100)  NOT NULL,
    description         VARCHAR(500)  NULL,
    -- Comisión de la plataforma por categoría, ej: 25.00 = 25%
    platform_commission DECIMAL(5,2)  NOT NULL,

    CONSTRAINT CK_categories_commission CHECK (platform_commission BETWEEN 0 AND 100)
);

-- Comisiones preferenciales por instructor (override de la categoría)
-- Agregada porque el enunciado dice que la comisión puede ser por categoría o por instructor
CREATE TABLE instructor_commissions (
    id                 INT           IDENTITY(1,1) PRIMARY KEY,
    instructor_id      INT           NOT NULL,
    commission_percent DECIMAL(5,2)  NOT NULL,
    valid_from         DATETIME      NOT NULL,
    valid_until        DATETIME      NULL,

    CONSTRAINT FK_ic_instructor        FOREIGN KEY (instructor_id) REFERENCES users(id),
    CONSTRAINT CK_ic_commission        CHECK (commission_percent BETWEEN 0 AND 100),
    -- valid_until debe ser posterior a valid_from si se define
    CONSTRAINT CK_ic_dates             CHECK (valid_until IS NULL OR valid_until > valid_from)
);

-- Mismo patrón que UX_reviews_active: a nivel de motor, un instructor solo
-- puede tener una comisión abierta (sin valid_until). Si dos administradores
-- registran una comisión al mismo tiempo, la segunda inserción falla con 2601.
CREATE UNIQUE INDEX UX_instructor_commissions_open
    ON instructor_commissions (instructor_id)
    WHERE valid_until IS NULL;

CREATE TABLE courses (
    id           INT           IDENTITY(1,1) PRIMARY KEY,
    -- Código auto-generado formato EDU-YYYY-NNNNN
    code         VARCHAR(20)   NOT NULL,
    title        VARCHAR(200)  NOT NULL,
    description  VARCHAR(MAX)  NULL,
    category_id  INT           NOT NULL,
    price        DECIMAL(10,2) NOT NULL,
    cover_image  VARCHAR(500)  NULL,
    -- Flujo de estado: pending → under_review → approved/rejected → available
    status       VARCHAR(20)   NOT NULL,
    created_at   DATETIME      NOT NULL DEFAULT GETDATE(),
    published_at DATETIME      NULL,
    featured     BIT           NOT NULL DEFAULT 0,

    CONSTRAINT UQ_courses_code      UNIQUE (code),
    CONSTRAINT FK_courses_category  FOREIGN KEY (category_id) REFERENCES categories(id),
    CONSTRAINT CK_courses_price     CHECK (price > 0),
    CONSTRAINT CK_courses_status    CHECK (status IN ('pending', 'under_review', 'approved', 'rejected', 'available', 'suspended'))
);

-- Tabla puente para prerequisitos; el SP debe validar que no haya dependencias circulares
CREATE TABLE course_prerequisites (
    course_id       INT NOT NULL,
    prerequisite_id INT NOT NULL,

    CONSTRAINT PK_course_prerequisites PRIMARY KEY (course_id, prerequisite_id),
    CONSTRAINT FK_cp_course       FOREIGN KEY (course_id)       REFERENCES courses(id),
    CONSTRAINT FK_cp_prerequisite FOREIGN KEY (prerequisite_id) REFERENCES courses(id),
    -- Un curso no puede ser su propio prerequisito
    CONSTRAINT CK_cp_no_self      CHECK (course_id <> prerequisite_id)
);

-- Cambiado para guardar el % del instructor principal y co-instructores
-- La suma de todos los share_percent para un curso debe ser exactamente 100% (validado en SP)
CREATE TABLE course_instructors (
    id            INT          IDENTITY(1,1) PRIMARY KEY,
    course_id     INT          NOT NULL,
    instructor_id INT          NOT NULL,
    is_main       BIT          NOT NULL DEFAULT 0,
    share_percent DECIMAL(5,2) NOT NULL,

    CONSTRAINT UQ_ci_course_instructor UNIQUE (course_id, instructor_id),
    CONSTRAINT FK_ci_course            FOREIGN KEY (course_id)     REFERENCES courses(id),
    CONSTRAINT FK_ci_instructor        FOREIGN KEY (instructor_id) REFERENCES users(id),
    CONSTRAINT CK_ci_share             CHECK (share_percent > 0 AND share_percent <= 100)
);

-- ============================================================
-- ACADEMIC REVIEW
-- ============================================================

-- Un curso puede tener múltiples revisiones si es rechazado y reenviado.
-- result puede ser NULL mientras la revisión está en curso (in_progress).
-- Flujo de status en courses: pending → under_review → approved/rejected
-- Si rechazado: instructor corrige → vuelve a pending → nuevo ciclo.
-- 'draft' no existe en el CHECK de courses; el estado post-rechazo es 'rejected'.
CREATE TABLE academic_reviews (
    id          INT          IDENTITY(1,1) PRIMARY KEY,
    course_id   INT          NOT NULL,
    reviewer_id INT          NOT NULL,
    result      VARCHAR(20)  NULL,    -- NULL mientras está in_progress
    comments    VARCHAR(MAX) NULL,
    started_at  DATETIME     NOT NULL,
    finished_at DATETIME     NULL,

    CONSTRAINT FK_ar_course    FOREIGN KEY (course_id)   REFERENCES courses(id),
    CONSTRAINT FK_ar_reviewer  FOREIGN KEY (reviewer_id) REFERENCES users(id),
    CONSTRAINT CK_ar_result    CHECK (result IS NULL OR result IN ('approved', 'rejected')),
    CONSTRAINT CK_ar_dates     CHECK (finished_at IS NULL OR finished_at >= started_at)
);

-- ============================================================
-- GAP 6: CONCURRENCY & REVIEW STATUS CONTROL
-- ============================================================

-- Estado explícito del flujo de revisión.
-- Permite filtrar revisiones activas sin depender de finished_at IS NULL,
-- que sería frágil ante registros incompletos o abandonados.
ALTER TABLE academic_reviews
    ADD status VARCHAR(20) NOT NULL DEFAULT 'in_progress';

ALTER TABLE academic_reviews
    ADD CONSTRAINT CK_ar_status CHECK (status IN ('in_progress', 'finished'));

-- Mismo patrón que UX_enrollments_active.
-- Garantiza a nivel de motor que dos académicos no puedan tomar el mismo
-- curso simultáneamente. La segunda inserción falla con Error 2601/2627
-- sin necesidad de validación adicional en el SP.
-- Al hacer UPDATE status = 'finished', el registro sale del índice
-- automáticamente, liberando el curso para un nuevo ciclo si fue rechazado.
CREATE UNIQUE INDEX UX_reviews_active
    ON academic_reviews (course_id)
    WHERE status = 'in_progress';

-- ============================================================
-- CONTENT STRUCTURE
-- ============================================================

-- order_index secuencial y sin huecos dentro del curso (validado en SP)
CREATE TABLE modules (
    id          INT          IDENTITY(1,1) PRIMARY KEY,
    course_id   INT          NOT NULL,
    title       VARCHAR(200) NOT NULL,
    description VARCHAR(500) NULL,
    order_index INT          NOT NULL,

    CONSTRAINT UQ_modules_order   UNIQUE (course_id, order_index),
    CONSTRAINT FK_modules_course  FOREIGN KEY (course_id) REFERENCES courses(id),
    CONSTRAINT CK_modules_order   CHECK (order_index > 0)
);

CREATE TABLE lessons (
    id           INT          IDENTITY(1,1) PRIMARY KEY,
    module_id    INT          NOT NULL,
    title        VARCHAR(200) NOT NULL,
    type         VARCHAR(20)  NOT NULL,
    content_url  VARCHAR(500) NULL,
    -- duration_min se usa para detectar tiempos de completado implausibles
    duration_min INT          NULL,
    order_index  INT          NOT NULL,

    CONSTRAINT UQ_lessons_order   UNIQUE (module_id, order_index),
    CONSTRAINT FK_lessons_module  FOREIGN KEY (module_id) REFERENCES modules(id),
    CONSTRAINT CK_lessons_type    CHECK (type IN ('video', 'document', 'quiz')),
    CONSTRAINT CK_lessons_order   CHECK (order_index > 0),
    CONSTRAINT CK_lessons_dur     CHECK (duration_min IS NULL OR duration_min > 0)
);

-- ============================================================
-- COHORTS AND SLOTS
-- ============================================================

-- Solo cursos en vivo usan cohortes con cupo limitado
CREATE TABLE cohorts (
    id             INT          IDENTITY(1,1) PRIMARY KEY,
    course_id      INT          NOT NULL,
    name           VARCHAR(100) NULL,
    starts_at      DATETIME     NOT NULL,
    ends_at        DATETIME     NULL,
    max_capacity   INT          NOT NULL,
    -- occupied_slots debe actualizarse con lock para evitar sobreventa
    occupied_slots INT          NOT NULL DEFAULT 0,
    active         BIT          NOT NULL DEFAULT 1,

    CONSTRAINT FK_cohorts_course       FOREIGN KEY (course_id) REFERENCES courses(id),
    CONSTRAINT CK_cohorts_capacity     CHECK (max_capacity > 0),
    CONSTRAINT CK_cohorts_occupied     CHECK (occupied_slots >= 0),
    -- El cupo ocupado nunca puede superar el máximo
    CONSTRAINT CK_cohorts_slots_max    CHECK (occupied_slots <= max_capacity),
    CONSTRAINT CK_cohorts_dates        CHECK (ends_at IS NULL OR ends_at > starts_at)
);

-- ============================================================
-- REFUND POLICY
-- ============================================================

-- La política aplicada es la vigente al momento de la inscripción, no la actual
CREATE TABLE refund_policies (
    id                   INT           IDENTITY(1,1) PRIMARY KEY,
    deadline_days        INT           NOT NULL,
    max_progress_percent DECIMAL(5,2)  NOT NULL,
    valid_from           DATETIME      NOT NULL,
    valid_until          DATETIME      NULL,
    active               BIT           NOT NULL DEFAULT 1,

    CONSTRAINT CK_rp_deadline  CHECK (deadline_days > 0),
    CONSTRAINT CK_rp_progress  CHECK (max_progress_percent BETWEEN 0 AND 100),
    CONSTRAINT CK_rp_dates     CHECK (valid_until IS NULL OR valid_until > valid_from)
);

-- Garantiza a nivel de motor una sola política vigente (active = 1) en toda
-- la plataforma; mismo patrón que UX_reviews_active.
CREATE UNIQUE INDEX UX_refund_policies_active
    ON refund_policies (active)
    WHERE active = 1;

-- ============================================================
-- ENROLLMENTS
-- ============================================================

-- period_id se asigna al momento de la liquidación
-- La validación de "no dos inscripciones activas" se hace en el SP con un índice filtrado
CREATE TABLE enrollments (
    id                INT           IDENTITY(1,1) PRIMARY KEY,
    student_id        INT           NOT NULL,
    course_id         INT           NOT NULL,
    cohort_id         INT           NULL,
    refund_policy_id  INT           NOT NULL,
    amount_paid       DECIMAL(10,2) NOT NULL,
    status            VARCHAR(20)   NOT NULL,
    -- settlement_status separado para manejar inscripción y pago como procesos distintos
    settlement_status VARCHAR(20)   NOT NULL DEFAULT 'pending',
    progress_percent  DECIMAL(5,2)  NOT NULL DEFAULT 0,
    enrolled_at       DATETIME      NOT NULL DEFAULT GETDATE(),
    completed_at      DATETIME      NULL,
    period_id         INT           NULL,

    CONSTRAINT FK_enr_student   FOREIGN KEY (student_id)       REFERENCES users(id),
    CONSTRAINT FK_enr_course    FOREIGN KEY (course_id)        REFERENCES courses(id),
    CONSTRAINT FK_enr_cohort    FOREIGN KEY (cohort_id)        REFERENCES cohorts(id),
    CONSTRAINT FK_enr_policy    FOREIGN KEY (refund_policy_id) REFERENCES refund_policies(id),
    CONSTRAINT CK_enr_status    CHECK (status            IN ('active', 'completed', 'refunded')),
    CONSTRAINT CK_enr_settle    CHECK (settlement_status IN ('pending', 'settled')),
    CONSTRAINT CK_enr_progress  CHECK (progress_percent  BETWEEN 0 AND 100),
    CONSTRAINT CK_enr_amount    CHECK (amount_paid > 0),
    CONSTRAINT CK_enr_dates     CHECK (completed_at IS NULL OR completed_at >= enrolled_at)
);

-- Índice filtrado: garantiza que no existan dos inscripciones activas
-- del mismo estudiante en el mismo curso al mismo tiempo
CREATE UNIQUE INDEX UX_enrollments_active
    ON enrollments (student_id, course_id)
    WHERE status = 'active';

-- Índices de soporte para JOINs frecuentes.
-- No se crea un índice solo por course_id: IX_enrollments_course_settlement
-- (Gap 4) empieza por course_id y ya cubre esas búsquedas.
CREATE INDEX IX_enrollments_student  ON enrollments (student_id);
CREATE INDEX IX_enrollments_period   ON enrollments (period_id);

-- ============================================================
-- MODULE PROGRESS
-- ============================================================

-- version para control de concurrencia optimista (múltiples dispositivos)
CREATE TABLE module_progress (
    id            INT      IDENTITY(1,1) PRIMARY KEY,
    enrollment_id INT      NOT NULL,
    module_id     INT      NOT NULL,
    completed     BIT      NOT NULL DEFAULT 0,
    completed_at  DATETIME NULL,
    version       INT      NOT NULL DEFAULT 0,

    CONSTRAINT UQ_mp_enrollment_module UNIQUE (enrollment_id, module_id),
    CONSTRAINT FK_mp_enrollment        FOREIGN KEY (enrollment_id) REFERENCES enrollments(id),
    CONSTRAINT FK_mp_module            FOREIGN KEY (module_id)     REFERENCES modules(id),
    CONSTRAINT CK_mp_version           CHECK (version >= 0)
);

-- sp_CompleteModule recalcula el progreso contando los modulos completados de
-- la inscripcion. Sin este indice cubriente el conteo hace un scan del indice
-- clustered y choca con las filas recien insertadas (aun sin confirmar) de
-- otras inscripciones: con varios estudiantes terminando a la vez se probaron
-- deadlocks reales. Con el Index Seek cada sesion solo toca sus propias filas.
CREATE INDEX IX_module_progress_enrollment
    ON module_progress (enrollment_id)
    INCLUDE (module_id, completed);

-- ============================================================
-- LESSON PROGRESS
-- ============================================================

-- Registra el inicio y fin de cada lección por estudiante.
-- Permite calcular tiempo efectivo de estudio para detección de fraude:
--   SUM(DATEDIFF(SECOND, started_at, completed_at)) / 60.0
-- Este acumulado se compara contra SUM(lessons.duration_min) del curso.
-- Usar MAX(completed_at) - MIN(started_at) sería incorrecto porque incluye
-- tiempo muerto entre sesiones; la suma por lección es el dato exacto.
-- Depende de enrollments (creada arriba) y lessons (creada en CONTENT STRUCTURE).
CREATE TABLE lesson_progress (
    id            INT      IDENTITY(1,1) PRIMARY KEY,
    enrollment_id INT      NOT NULL,
    lesson_id     INT      NOT NULL,
    started_at    DATETIME NOT NULL DEFAULT GETDATE(),
    completed_at  DATETIME NULL,
    -- Concurrencia optimista: mismo patrón que module_progress
    version       INT      NOT NULL DEFAULT 0,

    CONSTRAINT UQ_lp_enrollment_lesson UNIQUE (enrollment_id, lesson_id),
    CONSTRAINT FK_lp_enrollment        FOREIGN KEY (enrollment_id) REFERENCES enrollments(id),
    CONSTRAINT FK_lp_lesson            FOREIGN KEY (lesson_id)     REFERENCES lessons(id),
    CONSTRAINT CK_lp_dates             CHECK (completed_at IS NULL OR completed_at >= started_at),
    CONSTRAINT CK_lp_version           CHECK (version >= 0)
);

-- ============================================================
-- EXAMS
-- ============================================================

-- Un único examen final por curso
CREATE TABLE exams (
    id            INT           IDENTITY(1,1) PRIMARY KEY,
    course_id     INT           NOT NULL,
    title         VARCHAR(200)  NOT NULL,
    passing_score DECIMAL(5,2)  NOT NULL DEFAULT 70,
    max_attempts  INT           NOT NULL DEFAULT 3,

    CONSTRAINT UQ_exams_course    UNIQUE (course_id),
    CONSTRAINT FK_exams_course    FOREIGN KEY (course_id) REFERENCES courses(id),
    -- Nota mínima de aprobación entre 0 y 100
    CONSTRAINT CK_exams_passing   CHECK (passing_score BETWEEN 0 AND 100),
    CONSTRAINT CK_exams_attempts  CHECK (max_attempts > 0)
);

-- Cada intento queda registrado; passed se deriva comparando score con passing_score
CREATE TABLE exam_attempts (
    id             INT           IDENTITY(1,1) PRIMARY KEY,
    exam_id        INT           NOT NULL,
    enrollment_id  INT           NOT NULL,
    attempt_number INT           NOT NULL,
    score          DECIMAL(5,2)  NOT NULL,
    attempted_at   DATETIME      NOT NULL DEFAULT GETDATE(),

    CONSTRAINT UQ_ea_attempt      UNIQUE (exam_id, enrollment_id, attempt_number),
    CONSTRAINT FK_ea_exam         FOREIGN KEY (exam_id)       REFERENCES exams(id),
    CONSTRAINT FK_ea_enrollment   FOREIGN KEY (enrollment_id) REFERENCES enrollments(id),
    -- Score entre 0 y 100
    CONSTRAINT CK_ea_score        CHECK (score BETWEEN 0 AND 100),
    CONSTRAINT CK_ea_attempt_num  CHECK (attempt_number > 0)
);

-- ============================================================
-- CERTIFICATES
-- ============================================================

-- code: correlativo por año, único y sin huecos (gestionado con certificate_counters)
CREATE TABLE certificates (
    id            INT          IDENTITY(1,1) PRIMARY KEY,
    code          VARCHAR(30)  NOT NULL,
    enrollment_id INT          NOT NULL,
    issued_at     DATETIME     NOT NULL DEFAULT GETDATE(),
    status        VARCHAR(20)  NOT NULL,
    review_reason VARCHAR(500) NULL,

    CONSTRAINT UQ_cert_code       UNIQUE (code),
    CONSTRAINT UQ_cert_enrollment UNIQUE (enrollment_id),
    CONSTRAINT FK_cert_enrollment FOREIGN KEY (enrollment_id) REFERENCES enrollments(id),
    CONSTRAINT CK_cert_status     CHECK (status IN ('valid', 'pending_review', 'revoked'))
);

-- Controla el último correlativo por año; garantiza correlativos sin huecos
-- Se usa en lugar de SEQUENCE porque SEQUENCE no garantiza ausencia de huecos
CREATE TABLE certificate_counters (
    year        INT NOT NULL,
    last_number INT NOT NULL DEFAULT 0,

    CONSTRAINT PK_cert_counters  PRIMARY KEY (year),
    CONSTRAINT CK_cc_year        CHECK (year >= 2000),
    CONSTRAINT CK_cc_last_number CHECK (last_number >= 0)
);

-- Mismo patrón que certificate_counters pero para códigos de curso (EDU-YYYY-NNNNN).
-- Se prefiere sobre SEQUENCE porque SEQUENCE no reinicia por año de forma nativa;
-- lograrlo requeriría jobs externos o T-SQL dinámico, añadiendo fragilidad operacional.
-- El SP usa: UPDATE course_code_sequences WITH (UPDLOCK, ROWLOCK)
--            SET last_number = last_number + 1 WHERE year = @current_year
CREATE TABLE course_code_sequences (
    year        INT NOT NULL,
    last_number INT NOT NULL DEFAULT 0,

    CONSTRAINT PK_course_code_sequences PRIMARY KEY (year),
    CONSTRAINT CK_ccs_year              CHECK (year >= 2000),
    CONSTRAINT CK_ccs_number            CHECK (last_number >= 0)
);

-- ============================================================
-- BILLING PERIODS AND PAYOUTS
-- ============================================================

CREATE TABLE billing_periods (
    id           INT          IDENTITY(1,1) PRIMARY KEY,
    year         INT          NOT NULL,
    month        INT          NOT NULL,
    starts_at    DATETIME     NOT NULL,
    closes_at    DATETIME     NOT NULL,
    status       VARCHAR(20)  NOT NULL,
    processed_at DATETIME     NULL,

    CONSTRAINT UQ_bp_year_month  UNIQUE (year, month),
    -- Mes válido entre 1 y 12
    CONSTRAINT CK_bp_month       CHECK (month BETWEEN 1 AND 12),
    CONSTRAINT CK_bp_year        CHECK (year >= 2000),
    CONSTRAINT CK_bp_status      CHECK (status IN ('open', 'processing', 'closed')),
    CONSTRAINT CK_bp_dates       CHECK (closes_at > starts_at)
);

-- FK de enrollments a billing_periods (se agrega aquí porque billing_periods se crea después)
ALTER TABLE enrollments
    ADD CONSTRAINT FK_enr_period FOREIGN KEY (period_id) REFERENCES billing_periods(id);

-- Liquidación por curso por período
-- rounding_residue: el residuo se asigna al instructor principal (validado en SP)
CREATE TABLE course_settlements (
    id                  INT           IDENTITY(1,1) PRIMARY KEY,
    period_id           INT           NOT NULL,
    course_id           INT           NOT NULL,
    total_enrollments   INT           NOT NULL,
    gross_revenue       DECIMAL(12,2) NOT NULL,
    platform_commission DECIMAL(12,2) NOT NULL,
    -- Residuo de redondeo asignado al instructor principal
    rounding_residue    DECIMAL(12,2) NOT NULL DEFAULT 0,
    settled_at          DATETIME      NOT NULL DEFAULT GETDATE(),

    CONSTRAINT UQ_cs_period_course  UNIQUE (period_id, course_id),
    CONSTRAINT FK_cs_period         FOREIGN KEY (period_id) REFERENCES billing_periods(id),
    CONSTRAINT FK_cs_course         FOREIGN KEY (course_id) REFERENCES courses(id),
    CONSTRAINT CK_cs_enrollments    CHECK (total_enrollments >= 0),
    CONSTRAINT CK_cs_gross          CHECK (gross_revenue >= 0),
    CONSTRAINT CK_cs_commission     CHECK (platform_commission >= 0)
);

-- Detalle de cuánto recibe cada instructor en una liquidación
CREATE TABLE payouts (
    id                    INT           IDENTITY(1,1) PRIMARY KEY,
    settlement_id         INT           NOT NULL,
    course_instructor_id  INT           NOT NULL,
    participation_percent DECIMAL(5,2)  NOT NULL,
    negative_adjustments  DECIMAL(12,2) NOT NULL DEFAULT 0,
    net_amount            DECIMAL(12,2) NOT NULL,
    settled_at            DATETIME      NOT NULL DEFAULT GETDATE(),

    CONSTRAINT UQ_payouts_settlement_instructor UNIQUE (settlement_id, course_instructor_id),
    CONSTRAINT FK_payouts_settlement   FOREIGN KEY (settlement_id)        REFERENCES course_settlements(id),
    CONSTRAINT FK_payouts_ci           FOREIGN KEY (course_instructor_id) REFERENCES course_instructors(id),
    CONSTRAINT CK_payouts_percent      CHECK (participation_percent BETWEEN 0 AND 100),
    CONSTRAINT CK_payouts_adjustments  CHECK (negative_adjustments >= 0),
    -- net_amount puede ser negativo si los chargebacks superan la comisión del período
    -- No se define lower bound estático: el SP garantiza que el acumulado negativo
    -- no puede superar el historial de comisiones del instructor
);

-- ============================================================
-- CHARGEBACKS
-- ============================================================

-- Generado cuando se solicita reembolso sobre un período ya liquidado.
-- El ajuste negativo se aplica en la siguiente liquidación del instructor.
-- status + remaining_amount permiten al SP de liquidación hacer un Index Seek
-- directo sin JOIN contra chargeback_applications para saber cuánto queda pendiente.
-- FK_cb_refund se agrega después vía ALTER TABLE porque refunds se crea más adelante.
CREATE TABLE chargebacks (
    id                   INT           IDENTITY(1,1) PRIMARY KEY,
    course_instructor_id INT           NOT NULL,
    refund_id            INT           NOT NULL,
    origin_period_id     INT           NOT NULL,
    -- Monto negativo: cantidad total a descontar (nunca cambia tras la inserción)
    adjustment_amount    DECIMAL(12,2) NOT NULL,

    CONSTRAINT FK_cb_course_instructor FOREIGN KEY (course_instructor_id) REFERENCES course_instructors(id),
    CONSTRAINT FK_cb_origin_period     FOREIGN KEY (origin_period_id)     REFERENCES billing_periods(id),
    CONSTRAINT CK_cb_adjustment        CHECK (adjustment_amount < 0)
);

-- Registro de qué chargebacks se aplicaron en qué payout (tabla de auditoría).
-- chargeback_applications sigue existiendo para trazabilidad histórica completa,
-- pero el SP de liquidación no la necesita para calcular saldos pendientes;
-- usa remaining_amount directamente desde chargebacks.
CREATE TABLE chargeback_applications (
    id             INT           IDENTITY(1,1) PRIMARY KEY,
    chargeback_id  INT           NOT NULL,
    payout_id      INT           NOT NULL,
    amount_applied DECIMAL(12,2) NOT NULL,
    applied_at     DATETIME      NOT NULL DEFAULT GETDATE(),

    CONSTRAINT UQ_ca_chargeback_payout UNIQUE (chargeback_id, payout_id),
    CONSTRAINT FK_ca_chargeback        FOREIGN KEY (chargeback_id) REFERENCES chargebacks(id),
    CONSTRAINT FK_ca_payout            FOREIGN KEY (payout_id)     REFERENCES payouts(id),
    CONSTRAINT CK_ca_amount            CHECK (amount_applied <> 0)
);

-- ============================================================
-- GAP 5: CHARGEBACK STATUS AND REMAINING BALANCE TRACKING
-- ============================================================

-- status: permite filtrar chargebacks pendientes sin calcular el remanente en cada query.
-- remaining_amount: desnormalización justificada — el SP de liquidación hace un
--   Index Seek O(1) en lugar de un LEFT JOIN acumulativo contra chargeback_applications.
--   La sincronización es ACID: remaining_amount y chargeback_applications se actualizan
--   dentro del mismo BEGIN TRANSACTION, por lo que nunca pueden quedar desincronizados.
--
-- NOTA sobre remaining_amount NOT NULL sin DEFAULT:
--   SQL Server no permite DEFAULT que referencie otra columna de la misma fila.
--   El SP de inserción es responsable de setearlo a ABS(adjustment_amount).
--   En un ambiente con datos existentes, esta columna requeriría un DEFAULT
--   temporal o una migración explícita antes de eliminar la nullabilidad.
ALTER TABLE chargebacks
    ADD status           VARCHAR(20)   NOT NULL DEFAULT 'pending',
        remaining_amount DECIMAL(12,2) NOT NULL;

ALTER TABLE chargebacks
    ADD CONSTRAINT CK_cb_status    CHECK (status IN ('pending', 'partial', 'settled')),
        CONSTRAINT CK_cb_remaining CHECK (remaining_amount >= 0);

-- Índice diferido del Gap 4: depende de status y remaining_amount agregados aquí.
-- Index Covering: el SP de liquidación obtiene todos los saldos pendientes de un
-- instructor con un único Index Seek sin tocar las páginas de datos de la tabla.
CREATE INDEX IX_chargebacks_instructor_status
    ON chargebacks (course_instructor_id, status)
    INCLUDE (remaining_amount);

-- ============================================================
-- REFUNDS
-- ============================================================

-- Trazabilidad completa: quién solicitó, quién autorizó, monto, motivo, fecha
CREATE TABLE refunds (
    id            INT           IDENTITY(1,1) PRIMARY KEY,
    enrollment_id INT           NOT NULL,
    amount        DECIMAL(10,2) NOT NULL,
    reason        VARCHAR(500)  NOT NULL,
    status        VARCHAR(20)   NOT NULL,
    requested_at  DATETIME      NOT NULL DEFAULT GETDATE(),
    resolved_at   DATETIME      NULL,
    requested_by  INT           NOT NULL,
    authorized_by INT           NULL,

    CONSTRAINT FK_ref_enrollment   FOREIGN KEY (enrollment_id) REFERENCES enrollments(id),
    CONSTRAINT FK_ref_requested_by FOREIGN KEY (requested_by)  REFERENCES users(id),
    CONSTRAINT FK_ref_authorized   FOREIGN KEY (authorized_by) REFERENCES users(id),
    CONSTRAINT CK_ref_status       CHECK (status IN ('requested', 'approved', 'rejected')),
    CONSTRAINT CK_ref_amount       CHECK (amount > 0),
    CONSTRAINT CK_ref_dates        CHECK (resolved_at IS NULL OR resolved_at >= requested_at)
);

-- FKs diferidas: referencian tablas creadas después de su tabla origen
-- chargebacks → refunds (refunds se crea después de chargebacks)
ALTER TABLE chargebacks
    ADD CONSTRAINT FK_cb_refund FOREIGN KEY (refund_id) REFERENCES refunds(id);

-- wallet_movements → enrollments, refunds, payouts, chargebacks
ALTER TABLE wallet_movements
    ADD CONSTRAINT FK_wm_enrollment FOREIGN KEY (enrollment_id) REFERENCES enrollments(id);
ALTER TABLE wallet_movements
    ADD CONSTRAINT FK_wm_refund     FOREIGN KEY (refund_id)     REFERENCES refunds(id);
ALTER TABLE wallet_movements
    ADD CONSTRAINT FK_wm_payout     FOREIGN KEY (payout_id)     REFERENCES payouts(id);
ALTER TABLE wallet_movements
    ADD CONSTRAINT FK_wm_chargeback FOREIGN KEY (chargeback_id) REFERENCES chargebacks(id);

-- ============================================================
-- CATEGORY SUBSCRIPTIONS
-- ============================================================

-- Notificar a estudiantes cuando se publica un nuevo curso en su categoría suscrita
CREATE TABLE category_subscriptions (
    id            INT      IDENTITY(1,1) PRIMARY KEY,
    user_id       INT      NOT NULL,
    category_id   INT      NOT NULL,
    subscribed_at DATETIME NOT NULL DEFAULT GETDATE(),

    CONSTRAINT UQ_cs_user_category UNIQUE (user_id, category_id),
    CONSTRAINT FK_cs_user          FOREIGN KEY (user_id)     REFERENCES users(id),
    CONSTRAINT FK_cs_category      FOREIGN KEY (category_id) REFERENCES categories(id)
);

-- ============================================================
-- NOTIFICATION LOG
-- ============================================================

-- Cola de correos; un job externo maneja el envío real
CREATE TABLE notifications (
    id         INT          IDENTITY(1,1) PRIMARY KEY,
    user_id    INT          NOT NULL,
    type       VARCHAR(50)  NOT NULL,
    subject    VARCHAR(300) NULL,
    body       VARCHAR(MAX) NULL,
    sent       BIT          NOT NULL DEFAULT 0,
    created_at DATETIME     NOT NULL DEFAULT GETDATE(),

    CONSTRAINT FK_notif_user  FOREIGN KEY (user_id) REFERENCES users(id),
    CONSTRAINT CK_notif_type  CHECK (type IN (
        'course_received', 'approved', 'rejected', 'enrolled',
        'certificate', 'payout', 'refund', 'new_course'
    ))
);

-- ============================================================
-- GAP 4: OPTIMIZATION INDEXES
-- ============================================================
-- Justificación general: todos los índices aquí son Non-Clustered.
-- El costo DML (INSERT/UPDATE/DELETE) de cada uno es mínimo porque:
--   a) las tablas indexadas tienen baja frecuencia de escritura relativa a lectura,
--   b) los campos INCLUDE no forman parte de la clave B-Tree, por lo que
--      un UPDATE sobre ellos no reordena el árbol sino solo modifica el nodo hoja,
--   c) los índices filtrados son subconjuntos pequeños que se auto-reducen
--      conforme los registros cambian de estado.
-- La comparación de plan de ejecución antes/después se demostrará en los
-- reportes de "actividad de estudiantes" y "métricas por período" (fase 4).

-- Catálogo público: filtra siempre por status = 'available' y opcionalmente por categoría.
-- Costo DML casi nulo: un curso cambia de estado 3-4 veces en toda su vida.
CREATE INDEX IX_courses_status_category
    ON courses (status, category_id);

-- Motor de liquidación: obtiene inscripciones activas no liquidadas por curso.
-- INCLUDE evita Key Lookups sobre amount_paid y student_id en el mismo paso.
-- settlement_status se actualiza una sola vez al mes en el batch de liquidación.
CREATE INDEX IX_enrollments_course_settlement
    ON enrollments (course_id, settlement_status)
    INCLUDE (amount_paid, student_id);

-- Historial de billetera: siempre consultado por wallet ordenado por fecha DESC.
-- Tabla append-only (sin UPDATE/DELETE), created_at entra en orden secuencial
-- → sin page splits, fragmentación prácticamente nula.
CREATE INDEX IX_wallet_movements_wallet_date
    ON wallet_movements (wallet_id, created_at DESC);

-- SP de detección de fraude: suma DATEDIFF(SECOND, started_at, completed_at)
-- agrupado por enrollment_id. INCLUDE hace la query covering sin tocar tabla base.
-- UPDATE de completed_at no reordena el B-Tree porque no es clave del índice.
CREATE INDEX IX_lesson_progress_enrollment
    ON lesson_progress (enrollment_id)
    INCLUDE (started_at, completed_at);

-- Worker de correos: polling constante WHERE sent = 0 ORDER BY created_at.
-- Índice filtrado: solo contiene registros pendientes (~50 filas activas
-- sobre millones históricas). Al marcar sent = 1 la fila se remueve del índice,
-- manteniéndolo minúsculo y ultrarrápido.
CREATE INDEX IX_notifications_pending
    ON notifications (sent, created_at)
    INCLUDE (user_id, type)
    WHERE sent = 0;


