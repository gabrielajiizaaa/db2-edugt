CREATE OR ALTER PROCEDURE dbo.sp_IssueCertificate
	@enrollment_id		INT,
	@certificate_id		INT = NULL OUTPUT,
	@certificate_code	VARCHAR(30) = NULL OUTPUT,
	@certificate_status	VARCHAR(20) = NULL OUTPUT
AS
BEGIN
	SET NOCOUNT ON;
	SET XACT_ABORT ON;

	DECLARE
		@now				DATETIME = GETDATE(),
		@year				INT = YEAR(GETDATE()),
		@student_id			INT,
		@course_id			INT,
		@course_title		VARCHAR(200),
		@enr_status			VARCHAR(20),
		@total_modules		INT,
		@completed_modules	INT,
		@exam_id			INT,
		@passing_score		DECIMAL(5,2),
		@expected_min		DECIMAL(12,2),
		@effective_min		DECIMAL(12,2),
		@next_number		INT,
		@review_reason		VARCHAR(500) = NULL;

	DECLARE @min_time_ratio DECIMAL(5,2) = 0.30;

	BEGIN TRY

		-- INSCRIPCION VALIDA
		SELECT @student_id   = e.student_id,
		       @course_id    = e.course_id,
		       @enr_status   = e.status,
		       @course_title = c.title
		FROM enrollments e
		JOIN courses c ON c.id = e.course_id
		WHERE e.id = @enrollment_id;

		IF @student_id IS NULL
			THROW 57001, 'La inscripcion no existe.', 1;

		IF @enr_status = 'refunded'
			THROW 57002, 'La inscripcion fue reembolsada; no puede recibir certificado.', 1;

		-- CERTIFICADO DUPLICADO
		IF EXISTS (SELECT 1 FROM certificates WHERE enrollment_id = @enrollment_id)
			THROW 57003, 'Esta inscripcion ya tiene un certificado emitido.', 1;

		-- TODOS LOS MODULOS COMPLETADOS
		SELECT @total_modules = COUNT(*)
		FROM modules
		WHERE course_id = @course_id;

		SELECT @completed_modules = COUNT(*)
		FROM module_progress mp
		JOIN modules m ON m.id = mp.module_id
		WHERE mp.enrollment_id = @enrollment_id
		  AND m.course_id      = @course_id
		  AND mp.completed     = 1;

		IF @total_modules = 0 OR @completed_modules < @total_modules
			THROW 57004, 'El estudiante no ha completado todos los modulos del curso.', 1;

		-- EXAMEN FINAL APROBADO (solo si el curso tiene examen)
		SELECT @exam_id = id, @passing_score = passing_score
		FROM exams
		WHERE course_id = @course_id;

		IF @exam_id IS NOT NULL AND NOT EXISTS (
			SELECT 1 FROM exam_attempts
			WHERE exam_id       = @exam_id
			  AND enrollment_id = @enrollment_id
			  AND score        >= @passing_score
		) THROW 57005, 'El estudiante no ha aprobado el examen final.', 1;

		-- DETECCION DE FRAUDE POR TIEMPO IMPLAUSIBLE
		SELECT @expected_min = ISNULL(SUM(l.duration_min), 0)
		FROM lessons l
		JOIN modules m ON m.id = l.module_id
		WHERE m.course_id = @course_id;

		-- Tiempo efectivo, suma por leccion

		SELECT @effective_min = ISNULL(SUM(DATEDIFF(SECOND, started_at, completed_at)), 0) / 60.0
		FROM lesson_progress
		WHERE enrollment_id = @enrollment_id
		  AND completed_at IS NOT NULL;

		IF @expected_min > 0 AND @effective_min < @expected_min * @min_time_ratio
			SET @review_reason = CONCAT(
				'Tiempo implausible: ', @effective_min, ' min efectivos vs ',
				@expected_min, ' min de contenido (minimo requerido ',
				CAST(@min_time_ratio * 100 AS INT), '%).'
			);

		SET @certificate_status = CASE WHEN @review_reason IS NULL THEN 'valid' ELSE 'pending_review' END;

		BEGIN TRANSACTION;

		-- CORRELATIVO SIN HUECOS
		-- UPDLOCK + HOLDLOCK serializa a las sesiones que emiten al mismo tiempo
		
		UPDATE certificate_counters WITH (UPDLOCK, HOLDLOCK)
		SET @next_number = last_number = last_number + 1
		WHERE year = @year;

		IF @@ROWCOUNT = 0
		BEGIN
			INSERT INTO certificate_counters (year, last_number) VALUES (@year, 1);
			SET @next_number = 1;
		END

		-- CONCAT('CERT-EDU-', RIGHT(CONCAT('00000', @next_number), 5))
		SET @certificate_code = CONCAT('CERT-EDU-', @year, '-', RIGHT(CONCAT('00000', @next_number), 5));

		-- CERTIFICADO
		INSERT INTO certificates (code, enrollment_id, issued_at, status, review_reason)
		VALUES (@certificate_code, @enrollment_id, @now, @certificate_status, @review_reason);

		SET @certificate_id = SCOPE_IDENTITY();

		-- SOLO UN CERTIFICADO VALIDO CIERRA LA INSCRIPCION
		IF @certificate_status = 'valid'
			UPDATE enrollments
			SET status = 'completed',
				progress_percent = 100,
				completed_at = @now
			WHERE id = @enrollment_id;

		-- NOTIFICACION AL ESTUDIANTE
		INSERT INTO notifications (user_id, type, subject, body)
		VALUES (
			@student_id,
			'certificate',
			CASE WHEN @certificate_status = 'valid'
				 THEN 'Certificado emitido'
				 ELSE 'Certificado en revision' END,
			CASE WHEN @certificate_status = 'valid'
				 THEN CONCAT('Tu certificado ', @certificate_code, ' del curso ', @course_title, ' esta disponible.')
				 ELSE CONCAT('Tu certificado ', @certificate_code, ' del curso ', @course_title, ' esta en revision.') END
		);

		COMMIT TRANSACTION;

		SELECT @certificate_id AS certificate_id,
		       @certificate_code AS certificate_code,
		       @certificate_status AS certificate_status,
		       @review_reason AS review_reason;
	END TRY
	BEGIN CATCH
		IF XACT_STATE() <> 0
			ROLLBACK TRANSACTION;

		IF ERROR_NUMBER() IN (2601, 2627)
			THROW 57003, 'Esta inscripcion ya tiene un certificado emitido.', 1;

		THROW;
	END CATCH
END
GO