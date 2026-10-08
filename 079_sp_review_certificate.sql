
-- sp_ReviewCertificate
-- El comite academico resuelve un certificado marcado como sospechoso.
-- sp_IssueCertificate emite con status 'pending_review' cuando el tiempo de
-- estudio es implausible; el enunciado pide revisarlo "antes de considerarlo
-- valido". Este SP cierra ese ciclo:
--   - 'valid'   : el comite confirma que el avance es legitimo.
--   - 'revoked' : el comite lo anula (comentario obligatorio).
-- En ambos casos se notifica al estudiante.
--
-- La inscripcion se queda en 'completed': el estudiante si termino el
-- contenido; lo que se anula es el certificado. sp_EnrollStudent no acepta como
-- requisito previo aprobado un curso cuyo certificado este en revision o
-- revocado.
--
-- review_reason conserva el motivo original de la marca y se le agrega la
-- resolucion (decision, revisor y comentario), para que quede trazable quien
-- lo valido o revoco y por que.
--
-- Concurrencia: dos academicos resolviendo el mismo certificado a la vez.
-- El UPDATE esta condicionado a status = 'pending_review': el segundo espera
-- el bloqueo de la fila, reevalua la condicion con el valor ya confirmado por
-- el primero, no encuentra la fila (@@ROWCOUNT = 0) y recibe 63005. Nunca
-- quedan dos resoluciones distintas sobre el mismo certificado.

CREATE OR ALTER PROCEDURE dbo.sp_ReviewCertificate
    @academic_id    INT,
    @certificate_id INT,
    @decision       VARCHAR(20),
    @comments       VARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM users WHERE id = @academic_id AND role = 'academic' AND active = 1)
        THROW 63001, 'Solo un miembro activo del comite academico puede revisar certificados.', 1;

    IF @decision IS NULL OR @decision NOT IN ('valid', 'revoked')
        THROW 63002, 'La decision debe ser valid o revoked.', 1;

    IF @decision = 'revoked' AND (@comments IS NULL OR LTRIM(RTRIM(@comments)) = '')
        THROW 63003, 'Debe indicar el motivo de la revocacion.', 1;

    IF NOT EXISTS (SELECT 1 FROM certificates WHERE id = @certificate_id)
        THROW 63004, 'El certificado no existe.', 1;

    DECLARE @student_id INT, @course_title VARCHAR(200), @code VARCHAR(30);
    DECLARE @resolution VARCHAR(500) = CONCAT(
        ' | Resuelto como ', @decision, ' por el usuario ', @academic_id,
        ' el ', CONVERT(VARCHAR(19), GETDATE(), 120),
        CASE WHEN @comments IS NOT NULL THEN CONCAT(': ', @comments) ELSE '' END, '.');

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Cambio de estado atomico: solo se resuelve si sigue pendiente.
        -- LEFT(..., 500) respeta el tamano de review_reason.
        UPDATE certificates
            SET status        = @decision,
                review_reason = LEFT(CONCAT(review_reason, @resolution), 500)
        WHERE id = @certificate_id
          AND status = 'pending_review';

        IF @@ROWCOUNT = 0
            THROW 63005, 'El certificado no esta pendiente de revision (no fue marcado o ya fue resuelto).', 1;

        SELECT @student_id = e.student_id, @course_title = c.title, @code = cert.code
        FROM certificates cert
        JOIN enrollments e ON e.id = cert.enrollment_id
        JOIN courses c     ON c.id = e.course_id
        WHERE cert.id = @certificate_id;

        INSERT INTO notifications (user_id, type, subject, body)
        VALUES (
            @student_id, 'certificate',
            CASE WHEN @decision = 'valid'
                 THEN CONCAT('Tu certificado ', @code, ' fue validado')
                 ELSE CONCAT('Tu certificado ', @code, ' fue revocado')
            END,
            CASE WHEN @decision = 'valid'
                 THEN CONCAT('El comite academico reviso tu certificado del curso "', @course_title,
                             '" y lo confirmo como valido.')
                 ELSE CONCAT('El comite academico reviso tu certificado del curso "', @course_title,
                             '" y lo revoco. Motivo: ', @comments)
            END
        );

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
