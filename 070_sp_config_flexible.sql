
-- El enunciado indica que el administrador debe poder:
--   1. Configurar la comisión por categoria -> sp_SetCategoryCommission
--   2. Configurar la comisión por instructor -> sp_SetInstructorCommission
--   3. Definir cohortes (fecha inicio + cupo maximo) -> sp_CreateCohort
--   4. Establecer la política de reembolso vigente -> sp_SetRefundPolicy
--   5. Destacar manualmente cursos en la portada -> sp_SetCourseFeatured
--
-- Todos validan que quien ejecuta la accion tenga rol 'admin', porque el
-- enunciado atribuye estas configuraciones exclusivamente al administrador.

-- 1. sp_SetCategoryCommission
-- Actualiza el porcentaje de comisión de la plataforma para una categoria.
-- categories.platform_commission es un valor unico por categoria, por lo que
-- se actualiza en el lugar (no lleva historial en esta tabla).

CREATE OR ALTER PROCEDURE dbo.sp_SetCategoryCommission
    @admin_id           INT,
    @category_id        INT,
    @commission_percent DECIMAL(5,2)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM users WHERE id = @admin_id AND role = 'admin')
        THROW 55001, 'Solo un administrador puede configurar la comision de una categoria.', 1;

    IF NOT EXISTS (SELECT 1 FROM categories WHERE id = @category_id)
        THROW 55002, 'La categoria especificada no existe.', 1;

    IF @commission_percent IS NULL OR @commission_percent < 0 OR @commission_percent > 100
        THROW 55003, 'La comision debe estar entre 0 y 100.', 1;

    UPDATE categories
        SET platform_commission = @commission_percent
    WHERE id = @category_id;
END

-- 2. sp_SetInstructorCommission
-- Registra una comisión preferencial para un instructor (override de la
-- comisión por categoria). La tabla instructor_commissions no tiene columna
-- 'active': la vigencia se controla con valid_from / valid_until.
-- Al registrar una comisión nueva se cierra la anterior vigente poniendo su
-- valid_until = ahora, dejando historial completo de tasas aplicadas.

CREATE OR ALTER PROCEDURE dbo.sp_SetInstructorCommission
    @admin_id           INT,
    @instructor_id      INT,
    @commission_percent DECIMAL(5,2),
    @valid_from         DATETIME = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM users WHERE id = @admin_id AND role = 'admin')
        THROW 55101, 'Solo un administrador puede configurar la comision de un instructor.', 1;

    IF NOT EXISTS (SELECT 1 FROM users WHERE id = @instructor_id AND role = 'instructor')
        THROW 55102, 'El instructor especificado no existe o no tiene rol instructor.', 1;

    IF @commission_percent IS NULL OR @commission_percent < 0 OR @commission_percent > 100
        THROW 55103, 'La comision debe estar entre 0 y 100.', 1;

    -- Si no se indica fecha de inicio, la comisión rige desde ahora.
    IF @valid_from IS NULL
        SET @valid_from = GETDATE();

    -- La nueva comisión no puede empezar antes o al mismo tiempo que la vigente
    -- abierta del instructor, porque al cerrarla con valid_until = @valid_from
    -- se violaria CK_ic_dates (valid_until debe ser mayor que su valid_from).
    IF EXISTS (
        SELECT 1 FROM instructor_commissions
        WHERE instructor_id = @instructor_id AND valid_until IS NULL AND valid_from >= @valid_from
    )
        THROW 55104, 'La fecha de inicio debe ser posterior al inicio de la comision vigente del instructor.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Serializa por instructor: dos administradores registrando a la vez
        -- esperan en este punto, y la segunda sesion revalida con el estado ya
        -- actualizado por la primera. UX_instructor_commissions_open es la
        -- garantia final a nivel de motor.
        IF EXISTS (
            SELECT 1 FROM instructor_commissions WITH (UPDLOCK, HOLDLOCK)
            WHERE instructor_id = @instructor_id AND valid_until IS NULL AND valid_from >= @valid_from
        )
            THROW 55104, 'La fecha de inicio debe ser posterior al inicio de la comision vigente del instructor.', 1;

        -- Cerrar la comisión vigente anterior (la que no tiene fin definido).
        UPDATE instructor_commissions
            SET valid_until = @valid_from
        WHERE instructor_id = @instructor_id
          AND valid_until IS NULL;

        INSERT INTO instructor_commissions (instructor_id, commission_percent, valid_from, valid_until)
        VALUES (@instructor_id, @commission_percent, @valid_from, NULL);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        IF ERROR_NUMBER() IN (2601, 2627)
            THROW 55105, 'Otro administrador registro una comision para este instructor al mismo tiempo. Intente de nuevo.', 1;

        THROW;
    END CATCH
END

-- 3. sp_CreateCohort
-- Crea una cohorte (edicion en vivo) para un curso, con fecha de inicio,
-- fecha de fin opcional y cupo maximo. occupied_slots arranca en 0 por default.
CREATE OR ALTER PROCEDURE dbo.sp_CreateCohort
    @admin_id      INT,
    @course_id     INT,
    @name          VARCHAR(100) = NULL,
    @starts_at     DATETIME,
    @ends_at       DATETIME = NULL,
    @max_capacity  INT,
    @new_cohort_id INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM users WHERE id = @admin_id AND role = 'admin')
        THROW 55201, 'Solo un administrador puede crear cohortes.', 1;

    IF NOT EXISTS (SELECT 1 FROM courses WHERE id = @course_id)
        THROW 55202, 'El curso especificado no existe.', 1;

    IF @starts_at IS NULL
        THROW 55205, 'La fecha de inicio de la cohorte es obligatoria.', 1;

    IF @max_capacity IS NULL OR @max_capacity <= 0
        THROW 55203, 'El cupo maximo debe ser mayor a cero.', 1;

    IF @ends_at IS NOT NULL AND @ends_at <= @starts_at
        THROW 55204, 'La fecha de fin debe ser posterior a la fecha de inicio.', 1;

    INSERT INTO cohorts (course_id, name, starts_at, ends_at, max_capacity)
    VALUES (@course_id, @name, @starts_at, @ends_at, @max_capacity);

    SET @new_cohort_id = SCOPE_IDENTITY();
END

-- 4. sp_SetRefundPolicy
-- Establece la política de reembolso vigente de la plataforma. La política es
-- global (no por curso). Se inserta una fila nueva y se desactiva la anterior,
-- porque cada inscripcion guarda (snapshot) la política vigente al momento de
-- inscribirse; editar la fila existente rompería ese historial.
CREATE OR ALTER PROCEDURE dbo.sp_SetRefundPolicy
    @admin_id             INT,
    @deadline_days        INT,
    @max_progress_percent DECIMAL(5,2),
    @valid_from           DATETIME = NULL,
    @new_policy_id        INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM users WHERE id = @admin_id AND role = 'admin')
        THROW 55301, 'Solo un administrador puede establecer la politica de reembolso.', 1;

    IF @deadline_days IS NULL OR @deadline_days <= 0
        THROW 55302, 'El plazo en dias debe ser mayor a cero.', 1;

    IF @max_progress_percent IS NULL OR @max_progress_percent < 0 OR @max_progress_percent > 100
        THROW 55303, 'El porcentaje de avance maximo debe estar entre 0 y 100.', 1;

    IF @valid_from IS NULL
        SET @valid_from = GETDATE();

    -- La nueva política no puede empezar antes o al mismo tiempo que la vigente,
    -- porque al cerrar la anterior con valid_until = @valid_from se violaria
    -- CK_rp_dates (valid_until debe ser mayor que valid_from de la anterior).
    IF EXISTS (SELECT 1 FROM refund_policies WHERE active = 1 AND valid_from >= @valid_from)
        THROW 55304, 'La fecha de inicio debe ser posterior al inicio de la politica vigente.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Serializa a los administradores: la segunda sesion espera aqui y
        -- revalida contra la politica que acaba de crear la primera.
        -- UX_refund_policies_active es la garantia final a nivel de motor.
        IF EXISTS (SELECT 1 FROM refund_policies WITH (UPDLOCK, HOLDLOCK) WHERE active = 1 AND valid_from >= @valid_from)
            THROW 55304, 'La fecha de inicio debe ser posterior al inicio de la politica vigente.', 1;

        -- Cerrar la política vigente anterior: se desactiva y se le pone fin.
        UPDATE refund_policies
            SET active = 0,
                valid_until = @valid_from
        WHERE active = 1;

        INSERT INTO refund_policies (deadline_days, max_progress_percent, valid_from, valid_until, active)
        VALUES (@deadline_days, @max_progress_percent, @valid_from, NULL, 1);

        SET @new_policy_id = SCOPE_IDENTITY();

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        IF ERROR_NUMBER() IN (2601, 2627)
            THROW 55305, 'Otro administrador establecio una politica de reembolso al mismo tiempo. Intente de nuevo.', 1;

        THROW;
    END CATCH
END

-- 5. sp_SetCourseFeatured
-- Destaca o quita de destacados un curso en la portada (courses.featured).
-- Solo tiene sentido destacar cursos que ya estan disponibles en el catalogo.
CREATE OR ALTER PROCEDURE dbo.sp_SetCourseFeatured
    @admin_id  INT,
    @course_id INT,
    @featured  BIT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM users WHERE id = @admin_id AND role = 'admin')
        THROW 55401, 'Solo un administrador puede destacar cursos en la portada.', 1;

    IF @featured IS NULL
        THROW 55404, 'Debe indicar si el curso se destaca (1) o no (0).', 1;

    IF NOT EXISTS (SELECT 1 FROM courses WHERE id = @course_id)
        THROW 55402, 'El curso especificado no existe.', 1;

    -- Solo un curso disponible puede aparecer destacado en la portada.
    IF @featured = 1 AND NOT EXISTS (SELECT 1 FROM courses WHERE id = @course_id AND status = 'available')
        THROW 55403, 'Solo se puede destacar un curso que este disponible en el catalogo.', 1;

    UPDATE courses
        SET featured = @featured
    WHERE id = @course_id;
END