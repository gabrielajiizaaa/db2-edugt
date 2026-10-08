CREATE OR ALTER PROCEDURE dbo.sp_CompleteModule
	@enrollment_id		INT,
	@module_id			INT,
	@expected_version	INT = NULL,
	@progress_percent	DECIMAL(5,2) = NULL OUTPUT,
	@new_version		INT = NULL OUTPUT
AS
BEGIN
	SET NOCOUNT ON;
	SET XACT_ABORT ON;

	DECLARE
		@now				DATETIME = GETDATE(),
		@course_id			INT,
		@enr_status			VARCHAR(20),
		@mp_id				INT,
		@mp_completed		BIT,
		@mp_version			INT,
		@total_modules		INT,
		@completed_modules	INT;

	BEGIN TRY
		-- INSCRIPCION VALIDA
		SELECT @course_id = course_id, @enr_status = status
		FROM enrollments
		WHERE id = @enrollment_id;

		IF @course_id IS NULL
			THROW 58001, 'La inscripcion no existe.', 1;

		IF @enr_status <> 'active'
			THROW 58002, 'La inscripcion no esta activa (completada o reembolsada).', 1;

		-- EL MODULO PERTENECE AL CURSO
		IF NOT EXISTS (SELECT 1 FROM modules WHERE id = @module_id AND course_id = @course_id)
			THROW 58003, 'El modulo no existe o no pertenece al curso de la inscripcion.', 1;

		-- TODAS LAS LECCIONES DEL MODULO COMPLETADAS
		IF EXISTS (
			SELECT 1 FROM lessons l
			WHERE l.module_id = @module_id
			  AND NOT EXISTS (
				SELECT 1 FROM lesson_progress lp
				WHERE lp.enrollment_id = @enrollment_id
				  AND lp.lesson_id     = l.id
				  AND lp.completed_at IS NOT NULL
			  )
		) THROW 58004, 'El estudiante no ha completado todas las lecciones del modulo.', 1;

		-- LECTURA OPTIMISTA DEL PROGRESO DEL MODULO (SIN LOCK)
		SELECT @mp_id = id, @mp_completed = completed, @mp_version = version
		FROM module_progress
		WHERE enrollment_id = @enrollment_id AND module_id = @module_id;

		-- Si no hay registro, la version "vista" es 0
		IF @expected_version IS NOT NULL AND @expected_version <> ISNULL(@mp_version, 0)
			THROW 58006, 'El progreso fue modificado desde otro dispositivo. Reintente.', 1;

		IF @mp_completed = 1
			THROW 58005, 'El modulo ya estaba completado.', 1;

		BEGIN TRANSACTION;

		SELECT @enr_status = status
		FROM enrollments WITH (UPDLOCK, ROWLOCK)
		WHERE id = @enrollment_id;

		IF @enr_status <> 'active'
			THROW 58002, 'La inscripcion no esta activa (completada o reembolsada).', 1;

		IF @mp_id IS NULL
		BEGIN
			INSERT INTO module_progress (enrollment_id, module_id, completed, completed_at, version)
			VALUES (@enrollment_id, @module_id, 1, @now, 1);

			SET @new_version = 1;
		END
		ELSE
		BEGIN
			-- CONCURRENCIA OPTIMISTA: solo actualiza si nadie cambio la fila desde la lectura
			UPDATE module_progress
			SET completed    = 1,
				completed_at = @now,
				version      = version + 1
			WHERE id = @mp_id
			  AND version = @mp_version
			  AND completed = 0;

			IF @@ROWCOUNT = 0
				THROW 58006, 'El progreso fue modificado desde otro dispositivo. Reintente.', 1;

			SET @new_version = @mp_version + 1;
		END

		-- RECALCULO DEL PROGRESO
		SELECT @total_modules = COUNT(*)
		FROM modules
		WHERE course_id = @course_id;

		SELECT @completed_modules = COUNT(*)
		FROM module_progress mp
		JOIN modules m ON m.id = mp.module_id
		WHERE mp.enrollment_id = @enrollment_id
		  AND m.course_id      = @course_id
		  AND mp.completed     = 1;

		SET @progress_percent = CAST(@completed_modules * 100.0 / @total_modules AS DECIMAL(5,2));

		UPDATE enrollments
		SET progress_percent = @progress_percent
		WHERE id = @enrollment_id;

		COMMIT TRANSACTION;

		SELECT @progress_percent AS progress_percent,
		       @new_version      AS module_version,
		       @completed_modules AS completed_modules,
		       @total_modules     AS total_modules;
	END TRY
	BEGIN CATCH
		IF XACT_STATE() <> 0
			ROLLBACK TRANSACTION;

		-- Otro dispositivo creo el registro primero
		IF ERROR_NUMBER() IN (2601, 2627)
			THROW 58006, 'El progreso fue modificado desde otro dispositivo. Reintente.', 1;

		THROW;
	END CATCH
END
GO