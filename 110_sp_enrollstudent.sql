CREATE OR ALTER PROCEDURE dbo.sp_EnrollStudent
	@student_id					INT,
	@course_id					INT,
	@cohort_id					INT = NULL,
	@expected_wallet_version	INT = NULL,
	@enrollment_id				INT = NULL OUTPUT,
	@new_balance				DECIMAL(12,2) = NULL OUTPUT
AS
BEGIN
	SET NOCOUNT ON;
	SET XACT_ABORT ON;

	DECLARE
		@now				DATETIME = GETDATE(),
		@price				DECIMAL(10,2),
		@course_title		VARCHAR(200),
		@refund_policy_id	INT,
		@wallet_id			INT,
		@balance			DECIMAL(12,2),
		@version			INT;

	BEGIN TRY
		-- VALIDAR ESTUDIANTE
		IF NOT EXISTS (
			SELECT 1 FROM users WHERE id = @student_id AND role = 'student' AND active = 1
		) THROW 56001, 'El estudiante no existe, esta inactivo o no tiene rol student.', 1;

		-- CURSO DISPONIBLE
		SELECT @price = price, @course_title = title
		FROM courses
		WHERE id = @course_id AND status = 'available';

		IF @price IS NULL
			THROW 56002, 'El curso no existe o no esta disponible para inscripcion.', 1;

		-- INSCRIPCION DUPLICADA
		IF EXISTS (
			SELECT 1 FROM enrollments
			WHERE student_id = @student_id AND course_id = @course_id AND status IN ('active', 'completed')
		) THROW 56003, 'El estudiante ya tiene una inscripcion activa o completada en este curso.', 1;

		-- PREREQUISITOS: TODOS DEBEN ESTAR EN STATUS COMPLETED
		IF EXISTS (
			SELECT 1 FROM course_prerequisites cp
			WHERE cp.course_id = @course_id
			  AND NOT EXISTS (
				SELECT 1 FROM enrollments e
				WHERE e.student_id = @student_id
				  AND e.course_id  = cp.prerequisite_id
				  AND e.status     = 'completed'
			  )
		) THROW 56004, 'El estudiante no ha completado los prerequisitos del curso.', 1;

		-- COHORTE OBLIGATORIA SI EL CURSO TIENE COHORTES ACTIVAS
		IF @cohort_id IS NULL
		   AND EXISTS (SELECT 1 FROM cohorts WHERE course_id = @course_id AND active = 1)
			THROW 56005, 'Este curso es en vivo: debe seleccionar una cohorte.', 1;

		IF @cohort_id IS NOT NULL AND NOT EXISTS (
			SELECT 1 FROM cohorts
			WHERE id = @cohort_id
			  AND course_id = @course_id
			  AND active = 1
			  AND (ends_at IS NULL OR ends_at > @now)
		) THROW 56006, 'La cohorte no existe, no pertenece al curso o ya no esta activa.', 1;

		-- POLITICA DE REEMBOLSO VIGENTE AL MOMENTO DE INSCRIBIRSE
		SELECT TOP 1 @refund_policy_id = id
		FROM refund_policies
		WHERE active = 1
		  AND valid_from <= @now
		  AND (valid_until IS NULL OR valid_until > @now)
		ORDER BY valid_from DESC;

		IF @refund_policy_id IS NULL
			THROW 56008, 'No existe una politica de reembolso vigente.', 1;

		-- LECTURA DE LA BILLETERA (OPTIMISTA, SIN LOCK)
		SELECT @wallet_id = id, @balance = balance, @version = version
		FROM wallets
		WHERE user_id = @student_id;

		IF @wallet_id IS NULL
			THROW 56009, 'El estudiante no tiene billetera.', 1;

		IF @expected_wallet_version IS NOT NULL AND @expected_wallet_version <> @version
			THROW 56010, 'La billetera fue modificada por otra operacion. Reintente.', 1;

		IF @balance < @price
			THROW 56009, 'Saldo insuficiente en la billetera.', 1;

		BEGIN TRANSACTION;

		-- RESERVA DE CUPO ATOMICA
		IF @cohort_id IS NOT NULL
		BEGIN
			UPDATE cohorts
			SET occupied_slots = occupied_slots + 1
			WHERE id = @cohort_id AND occupied_slots < max_capacity;

			IF @@ROWCOUNT = 0
				THROW 56007, 'La cohorte ya no tiene cupo disponible.', 1;
		END

		-- COBRO CON CONCURRENCIA OPTIMISTA: SOLO COBRA SI NADIE CAMBIO LA BILLETERA DESDE LA LECTURA
		UPDATE wallets
		SET balance = balance - @price,
			version = version + 1
		WHERE id = @wallet_id
		  AND version = @version
		  AND balance >= @price;

		IF @@ROWCOUNT = 0
			THROW 56010, 'La billetera fue modificada por otra operacion. Reintente.', 1;

		SET @new_balance = @balance - @price;

		-- INSCRIPCION
		INSERT INTO enrollments (
			student_id, course_id, cohort_id, refund_policy_id,
			amount_paid, status, settlement_status, progress_percent, enrolled_at
		)
		VALUES (
			@student_id, @course_id, @cohort_id, @refund_policy_id,
			@price, 'active', 'pending', 0, @now
		);

		SET @enrollment_id = SCOPE_IDENTITY();

		-- MOVIMIENTO DE BILLETERA
		INSERT INTO wallet_movements (
			wallet_id, type, concept, amount, enrollment_id, created_at, resulting_balance
		)
		VALUES (
			@wallet_id, 'debit', 'enrollment', @price, @enrollment_id, @now, @new_balance
		);

		-- NOTIFICACION AL ESTUDIANTE
		INSERT INTO notifications (user_id, type, subject, body)
		VALUES (
			@student_id, 'enrolled', 'Inscripcion confirmada',
			'Te inscribiste en el curso: ' + @course_title
		);

		COMMIT TRANSACTION;

		SELECT @enrollment_id AS enrollment_id, @new_balance AS new_balance;
	END TRY
	BEGIN CATCH
		IF XACT_STATE() <> 0
			ROLLBACK TRANSACTION;

		-- CARRERA CONTRA UX_enrollments_active
		IF ERROR_NUMBER() IN (2601, 2627)
			THROW 56003, 'El estudiante ya tiene una inscripcion activa en este curso.', 1;

		THROW;
	END CATCH
END
GO
