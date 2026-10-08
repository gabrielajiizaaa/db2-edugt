
-- sp_RegisterExamAttempt
-- Registra un intento del examen final de un curso para una inscripcion.
-- Reglas:
--   - La nota debe estar entre 0 y 100.
--   - La inscripcion debe pertenecer al estudiante y estar activa.
--   - El curso debe tener examen final configurado (exams, uno por curso).
--   - No se permiten mas intentos que exams.max_attempts.
--   - Si el estudiante ya aprobo, no puede seguir registrando intentos.
--   - Si aprueba y ya completo el 100% de los modulos, se emite el certificado
--     automaticamente (sp_IssueCertificate) dentro de la misma transaccion.
--
-- Concurrencia: dos envios simultaneos del mismo estudiante (doble clic, dos
-- dispositivos) podrian leer el mismo numero de intentos y ambos pasar la
-- validacion de maximo. Se serializa por inscripcion tomando UPDLOCK sobre la
-- fila de enrollments antes de contar; la segunda sesion espera y al entrar ya
-- ve el intento de la primera. UQ_ea_attempt queda como red de seguridad.
-- sp_IssueCertificate bloquea la misma fila en el mismo orden (enrollments
-- primero), por lo que ambos SPs no generan deadlock entre si.

CREATE OR ALTER PROCEDURE dbo.sp_RegisterExamAttempt
    @enrollment_id  INT,
    @student_id     INT,
    @score          DECIMAL(5,2),
    @attempt_id     INT OUTPUT,
    @attempt_number INT OUTPUT,
    @passed         BIT OUTPUT,
    @certificate_code VARCHAR(30) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @score IS NULL OR @score < 0 OR @score > 100
        THROW 56001, 'La nota del examen debe estar entre 0 y 100.', 1;

    IF NOT EXISTS (SELECT 1 FROM enrollments WHERE id = @enrollment_id AND student_id = @student_id)
        THROW 56002, 'La inscripcion no existe o no pertenece a este estudiante.', 1;

    IF NOT EXISTS (SELECT 1 FROM enrollments WHERE id = @enrollment_id AND status = 'active')
        THROW 56003, 'Solo una inscripcion activa puede rendir el examen final.', 1;

    DECLARE @exam_id INT, @passing_score DECIMAL(5,2), @max_attempts INT, @course_id INT;
    SELECT @exam_id = ex.id, @passing_score = ex.passing_score, @max_attempts = ex.max_attempts,
           @course_id = e.course_id
    FROM enrollments e
    JOIN exams ex ON ex.course_id = e.course_id
    WHERE e.id = @enrollment_id;

    IF @exam_id IS NULL
        THROW 56004, 'El curso no tiene examen final configurado.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Bloquea la inscripcion: serializa intentos simultaneos y evita que un
        -- reembolso la cambie de estado mientras se registra el intento.
        DECLARE @enrollment_status VARCHAR(20);
        SELECT @enrollment_status = status
        FROM enrollments WITH (UPDLOCK, ROWLOCK)
        WHERE id = @enrollment_id;

        -- Se vuelve a validar bajo el bloqueo: pudo cambiar desde la validacion previa.
        IF @enrollment_status <> 'active'
            THROW 56003, 'Solo una inscripcion activa puede rendir el examen final.', 1;

        IF EXISTS (
            SELECT 1 FROM exam_attempts
            WHERE exam_id = @exam_id AND enrollment_id = @enrollment_id AND score >= @passing_score
        )
            THROW 56005, 'El estudiante ya aprobo el examen final; no puede registrar mas intentos.', 1;

        SELECT @attempt_number = ISNULL(MAX(attempt_number), 0) + 1
        FROM exam_attempts
        WHERE exam_id = @exam_id AND enrollment_id = @enrollment_id;

        IF @attempt_number > @max_attempts
        BEGIN
            DECLARE @max_msg VARCHAR(200) =
                CONCAT('Se alcanzo el maximo de intentos permitidos para este examen (', @max_attempts, ').');
            THROW 56006, @max_msg, 1;
        END

        INSERT INTO exam_attempts (exam_id, enrollment_id, attempt_number, score, attempted_at)
        VALUES (@exam_id, @enrollment_id, @attempt_number, @score, GETDATE());

        SET @attempt_id = SCOPE_IDENTITY();
        SET @passed = CASE WHEN @score >= @passing_score THEN 1 ELSE 0 END;
        SET @certificate_code = NULL;

        -- Emision automatica: aprobo y ya no le falta ningun modulo.
        IF @passed = 1 AND NOT EXISTS (
            SELECT 1 FROM modules m
            WHERE m.course_id = @course_id
              AND NOT EXISTS (
                  SELECT 1 FROM module_progress mp
                  WHERE mp.enrollment_id = @enrollment_id AND mp.module_id = m.id AND mp.completed = 1
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
            THROW 56007, 'Se registro otro intento simultaneo para esta inscripcion. Intente de nuevo.', 1;

        THROW;
    END CATCH
END
