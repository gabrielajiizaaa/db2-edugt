
-- sp_IssueCertificate
-- Emite el certificado de una inscripcion que completo el curso.
-- Normalmente no se llama a mano: lo disparan automaticamente
-- sp_CompleteModule (al completar el ultimo modulo) y sp_RegisterExamAttempt
-- (al aprobar el examen final), dentro de su misma transaccion.
-- Requisitos para emitir:
--   - La inscripcion pertenece al estudiante y no fue reembolsada.
--   - No existe ya un certificado para la inscripcion (UQ_cert_enrollment).
--   - El 100% de los modulos del curso esta completado (module_progress).
--   - Si el curso tiene examen final, el estudiante lo aprobo. El examen es
--     opcional: el enunciado indica "si la requiere".
--
-- Codigo: CERT-EDU-YYYY-NNNNN, correlativo por año y sin huecos.
-- Mismo patron que sp_CreateCourse con course_code_sequences: UPDLOCK + HOLDLOCK
-- al crear la fila del año y UPDATE con UPDLOCK para incrementar. Si la
-- transaccion hace ROLLBACK el numero se revierte, por lo que no quedan huecos.
-- El año va dentro del codigo porque el contador reinicia cada año; sin el año,
-- el primer certificado de cada año repetiria CERT-EDU-00001 y violaria UQ_cert_code.
--
-- Deteccion de fraude por tiempo implausible:
--   tiempo real    = SUM(DATEDIFF(SECOND, started_at, completed_at)) / 60.0 por leccion
--   tiempo esperado = SUM(lessons.duration_min)
-- Ambas sumas se calculan solo sobre lecciones con duration_min definido, para
-- comparar el mismo conjunto. Si el tiempo real es menor al @min_time_ratio del
-- esperado, el certificado se emite con status 'pending_review', el motivo queda
-- en review_reason y se notifica al comite academico; si no, se emite 'valid'.
-- Si ninguna leccion tiene duracion no hay contra que comparar y se emite 'valid'.

CREATE OR ALTER PROCEDURE dbo.sp_IssueCertificate
    @enrollment_id      INT,
    @student_id         INT,
    @certificate_id     INT OUTPUT,
    @certificate_code   VARCHAR(30) OUTPUT,
    @certificate_status VARCHAR(20) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Porcentaje minimo del tiempo esperado que debe registrar el estudiante.
    -- 0.50 = completar el curso en menos de la mitad de su duracion es sospechoso.
    DECLARE @min_time_ratio DECIMAL(4,2) = 0.50;

    IF NOT EXISTS (SELECT 1 FROM enrollments WHERE id = @enrollment_id AND student_id = @student_id)
        THROW 57001, 'La inscripcion no existe o no pertenece a este estudiante.', 1;

    IF NOT EXISTS (SELECT 1 FROM enrollments WHERE id = @enrollment_id AND status IN ('active', 'completed'))
        THROW 57002, 'No se puede emitir certificado para una inscripcion reembolsada.', 1;

    IF EXISTS (SELECT 1 FROM certificates WHERE enrollment_id = @enrollment_id)
        THROW 57003, 'Ya se emitio un certificado para esta inscripcion.', 1;

    DECLARE @course_id INT, @course_title VARCHAR(200);
    SELECT @course_id = c.id, @course_title = c.title
    FROM enrollments e
    JOIN courses c ON c.id = e.course_id
    WHERE e.id = @enrollment_id;

    DECLARE @exam_id INT, @passing_score DECIMAL(5,2);
    SELECT @exam_id = id, @passing_score = passing_score FROM exams WHERE course_id = @course_id;

    IF @exam_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM exam_attempts
        WHERE exam_id = @exam_id AND enrollment_id = @enrollment_id AND score >= @passing_score
    )
        THROW 57005, 'El estudiante no ha aprobado el examen final.', 1;

    IF EXISTS (
        SELECT 1 FROM modules m
        WHERE m.course_id = @course_id
          AND NOT EXISTS (
              SELECT 1 FROM module_progress mp
              WHERE mp.enrollment_id = @enrollment_id AND mp.module_id = m.id AND mp.completed = 1
          )
    )
        THROW 57006, 'El estudiante no ha completado todos los modulos del curso.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Bloquea la inscripcion: evita que un reembolso o una segunda emision
        -- simultanea la modifiquen mientras se emite el certificado.
        DECLARE @enrollment_status VARCHAR(20);
        SELECT @enrollment_status = status
        FROM enrollments WITH (UPDLOCK, ROWLOCK)
        WHERE id = @enrollment_id;

        IF @enrollment_status NOT IN ('active', 'completed')
            THROW 57002, 'No se puede emitir certificado para una inscripcion reembolsada.', 1;

        IF EXISTS (SELECT 1 FROM certificates WHERE enrollment_id = @enrollment_id)
            THROW 57003, 'Ya se emitio un certificado para esta inscripcion.', 1;

        -- Deteccion de fraude por tiempo implausible.
        DECLARE @expected_min DECIMAL(12,2), @actual_min DECIMAL(12,2);
        SELECT @expected_min = SUM(l.duration_min),
               @actual_min   = SUM(DATEDIFF(SECOND, lp.started_at, lp.completed_at)) / 60.0
        FROM lessons l
        JOIN modules m          ON m.id = l.module_id
        JOIN lesson_progress lp ON lp.lesson_id = l.id AND lp.enrollment_id = @enrollment_id
        WHERE m.course_id = @course_id
          AND l.duration_min IS NOT NULL
          AND lp.completed_at IS NOT NULL;

        -- Si el estudiante no registro ninguna leccion con duracion, el JOIN no
        -- trae filas; el tiempo esperado se toma igual del curso completo.
        IF @expected_min IS NULL
            SELECT @expected_min = SUM(l.duration_min)
            FROM lessons l
            JOIN modules m ON m.id = l.module_id
            WHERE m.course_id = @course_id;

        DECLARE @review_reason VARCHAR(500) = NULL;
        SET @certificate_status = 'valid';

        IF @expected_min > 0 AND ISNULL(@actual_min, 0) < @expected_min * @min_time_ratio
        BEGIN
            SET @certificate_status = 'pending_review';
            SET @review_reason = CONCAT(
                'Tiempo de estudio implausible: ', CAST(ISNULL(@actual_min, 0) AS DECIMAL(12,2)),
                ' min registrados contra ', @expected_min, ' min de duracion del curso (minimo ',
                CAST(@min_time_ratio * 100 AS INT), '%).');
        END

        DECLARE @year INT = YEAR(GETDATE());
        DECLARE @next_number INT;

        INSERT INTO certificate_counters (year, last_number)
        SELECT @year, 0
        WHERE NOT EXISTS (
            SELECT 1 FROM certificate_counters WITH (UPDLOCK, HOLDLOCK) WHERE year = @year
        );

        UPDATE certificate_counters WITH (UPDLOCK, ROWLOCK)
            SET last_number = last_number + 1,
                @next_number = last_number + 1
        WHERE year = @year;

        SET @certificate_code = CONCAT('CERT-EDU-', @year, '-', FORMAT(@next_number, 'D5'));

        INSERT INTO certificates (code, enrollment_id, issued_at, status, review_reason)
        VALUES (@certificate_code, @enrollment_id, GETDATE(), @certificate_status, @review_reason);

        SET @certificate_id = SCOPE_IDENTITY();

        -- El curso queda completado aunque el certificado este en revision:
        -- el estado del certificado es independiente del avance del estudiante.
        UPDATE enrollments
            SET status = 'completed',
                completed_at = ISNULL(completed_at, GETDATE())
        WHERE id = @enrollment_id;

        INSERT INTO notifications (user_id, type, subject, body)
        VALUES (
            @student_id, 'certificate',
            CASE WHEN @certificate_status = 'valid'
                 THEN CONCAT('Tu certificado de "', @course_title, '" fue emitido')
                 ELSE CONCAT('Tu certificado de "', @course_title, '" esta en revision')
            END,
            CASE WHEN @certificate_status = 'valid'
                 THEN CONCAT('Felicidades, completaste "', @course_title, '". Codigo de certificado: ', @certificate_code, '.')
                 ELSE CONCAT('Completaste "', @course_title, '". Tu certificado ', @certificate_code,
                             ' quedo en revision antes de ser validado.')
            END
        );

        -- Caso sospechoso: el comite academico debe revisarlo antes de validarlo.
        IF @certificate_status = 'pending_review'
            INSERT INTO notifications (user_id, type, subject, body)
            SELECT u.id, 'certificate',
                   CONCAT('Certificado ', @certificate_code, ' pendiente de verificacion'),
                   CONCAT('El certificado ', @certificate_code, ' del curso "', @course_title,
                          '" fue marcado para revision. ', @review_reason)
            FROM users u
            WHERE u.role = 'academic' AND u.active = 1;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        IF ERROR_NUMBER() IN (2601, 2627)
            THROW 57007, 'Ya se emitio un certificado para esta inscripcion (emision simultanea).', 1;

        THROW;
    END CATCH
END
