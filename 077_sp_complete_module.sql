
-- sp_CompleteModule
-- Marca un modulo como completado por el estudiante, registra el momento
-- exacto del avance, recalcula el porcentaje de progreso de la inscripcion y,
-- al llegar al 100% (y aprobar el examen final si el curso lo tiene), emite el
-- certificado automaticamente con sp_IssueCertificate en la misma transaccion.
--
-- Requisito: todas las lecciones del modulo deben estar completadas
-- (sp_CompleteLesson), para que el tiempo de estudio quede registrado.
--
-- CONCURRENCIA: un mismo estudiante avanzando desde varios dispositivos.
--   Riesgo 1, actualizacion perdida: dos sesiones leen progress_percent = 33,
--     cada una suma su modulo y ambas escriben 66; se pierde un avance.
--   Riesgo 2, modulo duplicado: ambas sesiones registran el mismo modulo.
--   Solucion:
--     a) UPDLOCK sobre la fila de enrollments al inicio de la transaccion:
--        las sesiones del mismo estudiante se forman en fila. La contencion es
--        minima (solo compiten los dispositivos de un mismo estudiante) y el
--        bloqueo dura lo que tarda el SP.
--     b) progress_percent no se incrementa sobre el valor leido: se recalcula
--        siempre contando los modulos completados en module_progress. Aunque
--        el orden de las sesiones varie, el resultado final es el correcto.
--     c) UQ_mp_enrollment_module garantiza a nivel de motor que un modulo no
--        quede registrado dos veces. Si el modulo ya estaba completado, el SP
--        no falla: devuelve @already_completed = 1 y el progreso actual
--        (operacion idempotente, el segundo dispositivo solo se sincroniza).
--     d) version en module_progress se incrementa en cada cambio de la fila.
--   Orden de bloqueo: enrollments -> certificate_counters (via
--   sp_IssueCertificate), el mismo que usa sp_RegisterExamAttempt.

CREATE OR ALTER PROCEDURE dbo.sp_CompleteModule
    @enrollment_id     INT,
    @student_id        INT,
    @module_id         INT,
    @progress_percent  DECIMAL(5,2) OUTPUT,
    @already_completed BIT OUTPUT,
    @certificate_code  VARCHAR(30) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM enrollments WHERE id = @enrollment_id AND student_id = @student_id)
        THROW 62001, 'La inscripcion no existe o no pertenece a este estudiante.', 1;

    IF NOT EXISTS (SELECT 1 FROM enrollments WHERE id = @enrollment_id AND status IN ('active', 'completed'))
        THROW 62002, 'La inscripcion no esta activa; no se puede registrar avance.', 1;

    DECLARE @course_id INT = (SELECT course_id FROM enrollments WHERE id = @enrollment_id);

    IF NOT EXISTS (SELECT 1 FROM modules WHERE id = @module_id AND course_id = @course_id)
        THROW 62003, 'El modulo no existe o no pertenece al curso de esta inscripcion.', 1;

    IF EXISTS (
        SELECT 1 FROM lessons l
        WHERE l.module_id = @module_id
          AND NOT EXISTS (
              SELECT 1 FROM lesson_progress lp
              WHERE lp.enrollment_id = @enrollment_id AND lp.lesson_id = l.id AND lp.completed_at IS NOT NULL
          )
    )
        THROW 62004, 'Debe completar todas las lecciones del modulo antes de marcarlo como completado.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Serializa los dispositivos del mismo estudiante sobre esta inscripcion.
        DECLARE @enrollment_status VARCHAR(20);
        SELECT @enrollment_status = status, @progress_percent = progress_percent
        FROM enrollments WITH (UPDLOCK, ROWLOCK)
        WHERE id = @enrollment_id;

        SET @already_completed = 0;
        SET @certificate_code = NULL;

        -- Otro dispositivo ya lo completo: solo se devuelve el estado actual.
        IF EXISTS (
            SELECT 1 FROM module_progress
            WHERE enrollment_id = @enrollment_id AND module_id = @module_id AND completed = 1
        )
        BEGIN
            SET @already_completed = 1;
            SELECT @certificate_code = code FROM certificates WHERE enrollment_id = @enrollment_id;
            COMMIT TRANSACTION;
            RETURN;
        END

        IF @enrollment_status <> 'active'
            THROW 62002, 'La inscripcion no esta activa; no se puede registrar avance.', 1;

        UPDATE module_progress
            SET completed    = 1,
                completed_at = GETDATE(),
                version      = version + 1
        WHERE enrollment_id = @enrollment_id AND module_id = @module_id AND completed = 0;

        IF @@ROWCOUNT = 0
            INSERT INTO module_progress (enrollment_id, module_id, completed, completed_at, version)
            VALUES (@enrollment_id, @module_id, 1, GETDATE(), 1);

        -- Recalculo desde la fuente (no incremento sobre el valor leido).
        DECLARE @total_modules INT, @completed_modules INT;
        SELECT @total_modules = COUNT(*) FROM modules WHERE course_id = @course_id;

        -- Solo se lee por enrollment_id (IX_module_progress_enrollment): un scan
        -- de la tabla chocaria con filas sin confirmar de otros estudiantes.
        -- No hace falta unir con modules: module_progress de esta inscripcion
        -- solo contiene modulos de su curso (validado con 62003).
        SELECT @completed_modules = COUNT(*)
        FROM module_progress
        WHERE enrollment_id = @enrollment_id AND completed = 1;

        SET @progress_percent = CAST(ROUND(@completed_modules * 100.0 / @total_modules, 2) AS DECIMAL(5,2));

        UPDATE enrollments
            SET progress_percent = @progress_percent
        WHERE id = @enrollment_id;

        -- Emision automatica: 100% de modulos y examen aprobado (si existe).
        IF @completed_modules = @total_modules
           AND NOT EXISTS (SELECT 1 FROM certificates WHERE enrollment_id = @enrollment_id)
           AND NOT EXISTS (
               SELECT 1 FROM exams ex
               WHERE ex.course_id = @course_id
                 AND NOT EXISTS (
                     SELECT 1 FROM exam_attempts ea
                     WHERE ea.exam_id = ex.id AND ea.enrollment_id = @enrollment_id
                       AND ea.score >= ex.passing_score
                 )
           )
        BEGIN
            DECLARE @certificate_id INT, @certificate_status VARCHAR(20);
            EXEC dbo.sp_IssueCertificate
                @enrollment_id      = @enrollment_id,
                @student_id         = @student_id,
                @certificate_id     = @certificate_id OUTPUT,
                @certificate_code   = @certificate_code OUTPUT,
                @certificate_status = @certificate_status OUTPUT;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        IF ERROR_NUMBER() IN (2601, 2627)
            THROW 62005, 'El modulo ya fue registrado por otra sesion. Intente de nuevo.', 1;

        THROW;
    END CATCH
END
